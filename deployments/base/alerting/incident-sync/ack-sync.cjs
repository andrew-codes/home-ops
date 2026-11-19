"use strict"

// Incident acknowledgement sync.
//
// Alertmanager creates one Jira work item per critical or service-down alert
// (the jira_configs receiver in vmalertmanager.yaml) but cannot read the work
// item back. This job closes that gap once a minute:
//
//   - A work item that is In Progress (status category "In Progress", so also
//     Verify) means the incident is acknowledged. The job silences that one
//     alert in Alertmanager, so its repeat pushes stop. The silence stays, and
//     is renewed with its own matchers, while the alert is briefly absent
//     (cleared, or flapping), so a recurrence stays silent too.
//   - A work item that is back in To Do or Done is not acknowledged. The job
//     removes the silence, so the alert pushes again at its next repeat.
//
// The same run also puts new incidents on the board. Alertmanager creates the
// work item in the backlog of the project's board, where nobody looks, so the
// job moves every open incident work item that is in the backlog onto the board
// (Jira Agile "Move issues to board"). Board or backlog placement is separate
// from status, so this changes neither the status nor the acknowledgement.
//
// Every silence is a short lease (SILENCE_TTL_MINUTES) that this job renews.
// If the job, Jira or the token breaks, the silences lapse and the pushes
// resume. Nothing here can mute an alert for good.
//
// The work item is tied to its alert by a label, alert-fp-<fingerprint>, which
// the receiver sets from the alert's Alertmanager fingerprint. The silence
// matches every label of that alert exactly.
//
// No dependencies, so it runs on the stock node image from a ConfigMap.

const SILENCE_CREATOR = "incident-ack-sync"
const FINGERPRINT_LABEL = /^alert-fp-([0-9a-f]+)$/
const ISSUE_KEY = /^([A-Z][A-Z0-9]*-\d+) /

const readConfig = (env) => {
  const required = (name) => {
    const value = env[name]
    if (!value) {
      throw new Error(`Missing required environment variable ${name}`)
    }
    return value
  }
  const ttlMinutes = Number(env.SILENCE_TTL_MINUTES || 15)
  if (!Number.isFinite(ttlMinutes) || ttlMinutes < 2) {
    throw new Error("SILENCE_TTL_MINUTES must be a number of at least 2")
  }
  const boardId = env.JIRA_BOARD_ID || "100"
  if (!/^\d+$/.test(boardId)) {
    throw new Error("JIRA_BOARD_ID must be a Jira board id (digits)")
  }
  return {
    jiraUrl: required("JIRA_URL").replace(/\/+$/, ""),
    jiraUser: required("JIRA_USER"),
    jiraApiToken: required("JIRA_API_TOKEN"),
    jiraProject: required("JIRA_PROJECT"),
    incidentLabel: env.INCIDENT_LABEL || "incident",
    jiraBoardId: boardId,
    alertmanagerUrl: required("ALERTMANAGER_URL").replace(/\/+$/, ""),
    ttlMs: ttlMinutes * 60 * 1000,
  }
}

const request = async (fetchImpl, url, options, what) => {
  const response = await fetchImpl(url, options)
  if (!response.ok) {
    const body = await response.text().catch(() => "")
    throw new Error(
      `${what} failed: HTTP ${response.status} ${body.slice(0, 300)}`,
    )
  }
  const text = await response.text()
  return text ? JSON.parse(text) : null
}

const jiraHeaders = (config) => ({
  Authorization: `Basic ${Buffer.from(
    `${config.jiraUser}:${config.jiraApiToken}`,
  ).toString("base64")}`,
  "Content-Type": "application/json",
  Accept: "application/json",
})

// The Agile API moves at most 50 work items per request and returns at most 50
// from the backlog by default.
const BOARD_BATCH = 50

// Open incident work items that are in the board's backlog. One page is enough:
// a run moves them, and anything beyond the page is picked up by the next run.
const findBacklogIncidents = async (config, fetchImpl) => {
  const jql = `project = "${config.jiraProject}" AND labels = "${config.incidentLabel}" AND statusCategory != "Done"`
  const query = new URLSearchParams({
    jql,
    fields: "key",
    maxResults: String(BOARD_BATCH),
  })
  const page = await request(
    fetchImpl,
    `${config.jiraUrl}/rest/agile/1.0/board/${config.jiraBoardId}/backlog?${query}`,
    { headers: jiraHeaders(config) },
    "Jira board backlog",
  )
  return (page?.issues ?? []).map((issue) => issue.key)
}

// Moves every open incident work item in the board's backlog onto the board.
// Returns the keys it moved.
const moveIncidentsToBoard = async (config, fetchImpl) => {
  const keys = await findBacklogIncidents(config, fetchImpl)
  for (let i = 0; i < keys.length; i += BOARD_BATCH) {
    const batch = keys.slice(i, i + BOARD_BATCH)
    await request(
      fetchImpl,
      `${config.jiraUrl}/rest/agile/1.0/board/${config.jiraBoardId}/issue`,
      {
        method: "POST",
        headers: jiraHeaders(config),
        body: JSON.stringify({ issues: batch }),
      },
      "Jira move to board",
    )
    for (const key of batch) {
      console.log(JSON.stringify({ action: "board", issue: key }))
    }
  }
  return keys
}

// Work items that are acknowledged: In Progress status category, labelled as
// incidents. Returns [{ key, fingerprint }]. A work item with no fingerprint
// label (made by hand) cannot be matched to an alert and is skipped.
const findAcknowledgedIncidents = async (config, fetchImpl) => {
  const jql = `project = "${config.jiraProject}" AND labels = "${config.incidentLabel}" AND statusCategory = "In Progress"`
  const incidents = []
  let nextPageToken
  do {
    const page = await request(
      fetchImpl,
      `${config.jiraUrl}/rest/api/3/search/jql`,
      {
        method: "POST",
        headers: jiraHeaders(config),
        body: JSON.stringify({
          jql,
          fields: ["labels"],
          maxResults: 100,
          ...(nextPageToken ? { nextPageToken } : {}),
        }),
      },
      "Jira search",
    )
    for (const issue of page.issues ?? []) {
      const fingerprint = (issue.fields?.labels ?? [])
        .map((label) => FINGERPRINT_LABEL.exec(label)?.[1])
        .find(Boolean)
      if (fingerprint) {
        incidents.push({ key: issue.key, fingerprint })
      }
    }
    nextPageToken = page.nextPageToken
  } while (nextPageToken)
  return incidents
}

const listAlerts = (config, fetchImpl) =>
  request(
    fetchImpl,
    `${config.alertmanagerUrl}/api/v2/alerts?active=true&silenced=true&inhibited=true`,
    { headers: { Accept: "application/json" } },
    "Alertmanager alert list",
  )

// Silences this job owns that are still in effect (active or pending), with
// the work item key read back from the comment.
const listManagedSilences = async (config, fetchImpl) => {
  const silences = await request(
    fetchImpl,
    `${config.alertmanagerUrl}/api/v2/silences`,
    { headers: { Accept: "application/json" } },
    "Alertmanager silence list",
  )
  return silences
    .filter(
      (silence) =>
        silence.createdBy === SILENCE_CREATOR &&
        (silence.status?.state === "active" ||
          silence.status?.state === "pending"),
    )
    .map((silence) => ({
      ...silence,
      key: ISSUE_KEY.exec(silence.comment ?? "")?.[1],
    }))
}

const toMatchers = (labels) =>
  Object.entries(labels)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([name, value]) => ({
      name,
      value,
      isRegex: false,
      isEqual: true,
    }))

const sameMatchers = (existing, wanted) => {
  const normalise = (matchers) =>
    JSON.stringify(
      matchers
        .filter((m) => !m.isRegex && m.isEqual !== false)
        .map((m) => [m.name, m.value])
        .sort(),
    )
  return (
    existing.length === wanted.length &&
    normalise(existing) === normalise(wanted)
  )
}

// Decides what to do. Pure: no network, no clock.
//   incidents: acknowledged work items [{ key, fingerprint }]
//   alerts:    Alertmanager alerts [{ fingerprint, labels }]
//   silences:  managed silences, each with a key
// Returns { create, extend, expire }.
const plan = ({ incidents, alerts, silences, now, ttlMs }) => {
  const alertByFingerprint = new Map(alerts.map((a) => [a.fingerprint, a]))
  const create = []
  const extend = []
  const expire = []
  const wantedKeys = new Set()

  for (const { key, fingerprint } of incidents) {
    wantedKeys.add(key)
    const alert = alertByFingerprint.get(fingerprint)
    const owned = silences.filter((s) => s.key === key)
    const matchers = alert ? toMatchers(alert.labels) : undefined
    // While the alert is live its labels decide which silence is current. While
    // it is absent (cleared, may fire again) the newest existing silence
    // carries the matchers, so the acknowledgement outlives a flap.
    const current = matchers
      ? owned.find((s) => sameMatchers(s.matchers, matchers))
      : [...owned].sort(
          (a, b) => Date.parse(b.endsAt) - Date.parse(a.endsAt),
        )[0]
    for (const stale of owned) {
      if (stale !== current) {
        expire.push({ id: stale.id, key })
      }
    }
    if (!current) {
      if (matchers) {
        create.push({ key, matchers })
      }
      continue
    }
    const remaining = Date.parse(current.endsAt) - now
    if (remaining < ttlMs / 2) {
      extend.push({
        key,
        id: current.id,
        startsAt: current.startsAt,
        matchers: matchers ?? current.matchers,
      })
    }
  }

  // A silence with no acknowledged work item behind it: the work item went
  // back to To Do, was resolved, or no longer exists.
  for (const silence of silences) {
    if (!silence.key || !wantedKeys.has(silence.key)) {
      expire.push({ id: silence.id, key: silence.key })
    }
  }

  return { create, extend, expire }
}

const silenceBody = ({ key, id, startsAt, matchers }, now, ttlMs) => ({
  ...(id ? { id } : {}),
  matchers,
  startsAt: startsAt ?? new Date(now).toISOString(),
  endsAt: new Date(now + ttlMs).toISOString(),
  createdBy: SILENCE_CREATOR,
  comment: `${key} is In Progress in Jira (acknowledged). Managed by ${SILENCE_CREATOR}, do not edit. It lapses by itself if the work item is not In Progress.`,
})

const run = async (
  config,
  { fetch: fetchImpl = fetch, now = Date.now() } = {},
) => {
  // The board step is independent of the acknowledgement sync: a failure in
  // either does not stop the other, then the run fails so the
  // IncidentAckSyncFailing alert still sees it.
  const failures = []
  const attempt = async (step) => {
    try {
      return await step()
    } catch (error) {
      failures.push(error)
      return undefined
    }
  }

  const moved = await attempt(() => moveIncidentsToBoard(config, fetchImpl))
  const changes = await attempt(() =>
    syncAcknowledgements(config, fetchImpl, now),
  )

  console.log(
    JSON.stringify({ action: "board-done", moved: moved?.length ?? 0 }),
  )
  if (failures.length > 0) {
    // The caller reports the first failure, so log the others here.
    for (const error of failures.slice(1)) {
      console.error(error.message)
    }
    throw failures[0]
  }
  return changes
}

const syncAcknowledgements = async (config, fetchImpl, now) => {
  // Read everything first. If Jira or Alertmanager is unreachable this throws
  // before anything changes, and the silences already in place simply run out.
  const incidents = await findAcknowledgedIncidents(config, fetchImpl)
  const alerts = await listAlerts(config, fetchImpl)
  const silences = await listManagedSilences(config, fetchImpl)

  const changes = plan({
    incidents,
    alerts,
    silences,
    now,
    ttlMs: config.ttlMs,
  })

  const post = (change) =>
    request(
      fetchImpl,
      `${config.alertmanagerUrl}/api/v2/silences`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(silenceBody(change, now, config.ttlMs)),
      },
      `Alertmanager silence for ${change.key}`,
    )

  for (const change of changes.create) {
    await post(change)
    console.log(JSON.stringify({ action: "silence", issue: change.key }))
  }
  for (const change of changes.extend) {
    await post(change)
    console.log(JSON.stringify({ action: "renew", issue: change.key }))
  }
  for (const change of changes.expire) {
    await request(
      fetchImpl,
      `${config.alertmanagerUrl}/api/v2/silence/${encodeURIComponent(change.id)}`,
      { method: "DELETE" },
      `Alertmanager silence delete for ${change.key ?? change.id}`,
    )
    console.log(
      JSON.stringify({ action: "unsilence", issue: change.key ?? null }),
    )
  }

  console.log(
    JSON.stringify({
      action: "done",
      acknowledged: incidents.length,
      silenced: changes.create.length,
      renewed: changes.extend.length,
      unsilenced: changes.expire.length,
    }),
  )
  return changes
}

module.exports = {
  readConfig,
  run,
  plan,
  moveIncidentsToBoard,
  toMatchers,
  SILENCE_CREATOR,
}

if (require.main === module) {
  run(readConfig(process.env)).catch((error) => {
    // fetch reports a network failure as just "fetch failed", the reason is in cause.
    console.error(
      error.cause ? `${error.message}: ${error.cause.message}` : error.message,
    )
    process.exit(1)
  })
}
