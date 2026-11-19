const {
  plan,
  readConfig,
  run,
  toMatchers,
  SILENCE_CREATOR,
} = require("../../../../deployments/base/alerting/incident-sync/ack-sync.cjs")

const MINUTE = 60 * 1000
const now = Date.parse("2026-11-17T12:00:00Z")
const ttlMs = 15 * MINUTE

const kubeletLabels = {
  alertname: "KubeletDown",
  severity: "critical",
  job: "kubernetes-nodes",
  instance: "k8s-main",
}
const kubelet = { fingerprint: "aaaa1111", labels: kubeletLabels }
const diskLabels = {
  alertname: "NodeFilesystemAlmostFull",
  severity: "critical",
  node: "k8s-main",
  mountpoint: "/",
}
const disk = { fingerprint: "bbbb2222", labels: diskLabels }

const managedSilence = (
  key: string,
  labels: Record<string, string>,
  endsInMinutes: number,
  id = `silence-${key}`,
) => ({
  id,
  key,
  createdBy: SILENCE_CREATOR,
  startsAt: new Date(now - 5 * MINUTE).toISOString(),
  endsAt: new Date(now + endsInMinutes * MINUTE).toISOString(),
  matchers: toMatchers(labels),
})

describe("plan", () => {
  test("Silences the alert of an acknowledged work item, matching every label exactly.", () => {
    const result = plan({
      incidents: [{ key: "HO-1", fingerprint: "aaaa1111" }],
      alerts: [kubelet, disk],
      silences: [],
      now,
      ttlMs,
    })

    expect(result.create).toEqual([
      {
        key: "HO-1",
        matchers: [
          {
            name: "alertname",
            value: "KubeletDown",
            isRegex: false,
            isEqual: true,
          },
          {
            name: "instance",
            value: "k8s-main",
            isRegex: false,
            isEqual: true,
          },
          {
            name: "job",
            value: "kubernetes-nodes",
            isRegex: false,
            isEqual: true,
          },
          {
            name: "severity",
            value: "critical",
            isRegex: false,
            isEqual: true,
          },
        ],
      },
    ])
    expect(result.extend).toEqual([])
    expect(result.expire).toEqual([])
  })

  test("Does nothing for an acknowledged work item whose alert is not firing.", () => {
    const result = plan({
      incidents: [{ key: "HO-1", fingerprint: "gone0000" }],
      alerts: [kubelet],
      silences: [],
      now,
      ttlMs,
    })

    expect(result).toEqual({ create: [], extend: [], expire: [] })
  })

  test("Leaves a silence that still has most of its lease.", () => {
    const result = plan({
      incidents: [{ key: "HO-1", fingerprint: "aaaa1111" }],
      alerts: [kubelet],
      silences: [managedSilence("HO-1", kubeletLabels, 12)],
      now,
      ttlMs,
    })

    expect(result).toEqual({ create: [], extend: [], expire: [] })
  })

  test("Renews a silence in place once half of its lease is used, keeping its start.", () => {
    const silence = managedSilence("HO-1", kubeletLabels, 5)
    const result = plan({
      incidents: [{ key: "HO-1", fingerprint: "aaaa1111" }],
      alerts: [kubelet],
      silences: [silence],
      now,
      ttlMs,
    })

    expect(result.create).toEqual([])
    expect(result.expire).toEqual([])
    expect(result.extend).toEqual([
      {
        key: "HO-1",
        id: "silence-HO-1",
        startsAt: silence.startsAt,
        matchers: toMatchers(kubeletLabels),
      },
    ])
  })

  test("Removes the silence when the work item is no longer acknowledged.", () => {
    const result = plan({
      incidents: [],
      alerts: [kubelet],
      silences: [managedSilence("HO-1", kubeletLabels, 12)],
      now,
      ttlMs,
    })

    expect(result).toEqual({
      create: [],
      extend: [],
      expire: [{ id: "silence-HO-1", key: "HO-1" }],
    })
  })

  test("Keeps and renews the silence, by id with its own matchers, while the alert is absent.", () => {
    const silence = managedSilence("HO-1", kubeletLabels, 5)
    const result = plan({
      incidents: [{ key: "HO-1", fingerprint: "aaaa1111" }],
      alerts: [],
      silences: [silence],
      now,
      ttlMs,
    })

    expect(result.create).toEqual([])
    expect(result.expire).toEqual([])
    expect(result.extend).toEqual([
      {
        key: "HO-1",
        id: "silence-HO-1",
        startsAt: silence.startsAt,
        matchers: toMatchers(kubeletLabels),
      },
    ])
  })

  test("Leaves a silence with most of its lease alone while the alert is absent.", () => {
    const result = plan({
      incidents: [{ key: "HO-1", fingerprint: "aaaa1111" }],
      alerts: [],
      silences: [managedSilence("HO-1", kubeletLabels, 12)],
      now,
      ttlMs,
    })

    expect(result).toEqual({ create: [], extend: [], expire: [] })
  })

  test("Keeps the same silence when a cleared alert fires again, with no duplicate.", () => {
    const silences = [managedSilence("HO-1", kubeletLabels, 12)]
    const incidents = [{ key: "HO-1", fingerprint: "aaaa1111" }]
    const cleared = plan({ incidents, alerts: [], silences, now, ttlMs })
    const refired = plan({
      incidents,
      alerts: [kubelet],
      silences,
      now: now + MINUTE,
      ttlMs,
    })

    expect(cleared).toEqual({ create: [], extend: [], expire: [] })
    expect(refired).toEqual({ create: [], extend: [], expire: [] })
  })

  test("Removes the silence once the work item is no longer acknowledged, even with the alert absent.", () => {
    const result = plan({
      incidents: [],
      alerts: [],
      silences: [managedSilence("HO-1", kubeletLabels, 12)],
      now,
      ttlMs,
    })

    expect(result).toEqual({
      create: [],
      extend: [],
      expire: [{ id: "silence-HO-1", key: "HO-1" }],
    })
  })

  test("Keeps only the newest silence while the alert is absent.", () => {
    const result = plan({
      incidents: [{ key: "HO-1", fingerprint: "aaaa1111" }],
      alerts: [],
      silences: [
        managedSilence("HO-1", kubeletLabels, 3, "old"),
        managedSilence("HO-1", kubeletLabels, 12, "new"),
      ],
      now,
      ttlMs,
    })

    expect(result.expire).toEqual([{ id: "old", key: "HO-1" }])
    expect(result.extend).toEqual([])
    expect(result.create).toEqual([])
  })

  test("Replaces a silence whose matchers no longer fit the alert.", () => {
    const result = plan({
      incidents: [{ key: "HO-1", fingerprint: "aaaa1111" }],
      alerts: [kubelet],
      silences: [
        managedSilence("HO-1", { ...kubeletLabels, instance: "old-node" }, 12),
      ],
      now,
      ttlMs,
    })

    expect(result.expire).toEqual([{ id: "silence-HO-1", key: "HO-1" }])
    expect(result.create).toHaveLength(1)
    expect(result.create[0].key).toEqual("HO-1")
  })

  test("Handles several incidents independently.", () => {
    const result = plan({
      incidents: [
        { key: "HO-1", fingerprint: "aaaa1111" },
        { key: "HO-2", fingerprint: "bbbb2222" },
      ],
      alerts: [kubelet, disk],
      silences: [
        managedSilence("HO-1", kubeletLabels, 12),
        managedSilence("HO-9", { alertname: "Old" }, 12),
      ],
      now,
      ttlMs,
    })

    expect(result.create.map((c: { key: string }) => c.key)).toEqual(["HO-2"])
    expect(result.expire).toEqual([{ id: "silence-HO-9", key: "HO-9" }])
  })

  test("Removes a managed silence it cannot tie to a work item.", () => {
    const result = plan({
      incidents: [],
      alerts: [],
      silences: [
        { ...managedSilence("HO-1", kubeletLabels, 12), key: undefined },
      ],
      now,
      ttlMs,
    })

    expect(result.expire).toEqual([{ id: "silence-HO-1", key: undefined }])
  })
})

describe("readConfig", () => {
  const env = {
    JIRA_URL: "https://example.atlassian.net/",
    JIRA_USER: "bot@example.test",
    JIRA_API_TOKEN: "token",
    JIRA_PROJECT: "HO",
    ALERTMANAGER_URL: "http://alertmanager:9093/",
  }

  test("Reads the settings, trims trailing slashes and defaults the lease to 15 minutes.", () => {
    expect(readConfig(env)).toEqual({
      jiraUrl: "https://example.atlassian.net",
      jiraUser: "bot@example.test",
      jiraApiToken: "token",
      jiraProject: "HO",
      incidentLabel: "incident",
      jiraBoardId: "100",
      alertmanagerUrl: "http://alertmanager:9093",
      ttlMs: 15 * MINUTE,
    })
  })

  test("Rejects a board id that is not a number.", () => {
    expect(() => readConfig({ ...env, JIRA_BOARD_ID: "../x" })).toThrow(
      "JIRA_BOARD_ID",
    )
  })

  test("Names the missing variable.", () => {
    const incomplete = Object.fromEntries(
      Object.entries(env).filter(([name]) => name !== "JIRA_API_TOKEN"),
    )
    expect(() => readConfig(incomplete)).toThrow("JIRA_API_TOKEN")
  })

  test("Rejects a lease too short to be renewed.", () => {
    expect(() => readConfig({ ...env, SILENCE_TTL_MINUTES: "1" })).toThrow(
      "SILENCE_TTL_MINUTES",
    )
  })
})

type Call = {
  method: string
  url: string
  body?: unknown
  headers?: Record<string, string>
}

const respond = (status: number, body: unknown) => ({
  ok: status >= 200 && status < 300,
  status,
  text: async () => (body === undefined ? "" : JSON.stringify(body)),
})

// A fake Jira and Alertmanager, recording every call.
const fakeServices = ({
  jiraPages,
  alerts = [],
  silences = [],
  jiraStatus = 200,
  backlog = [],
  backlogStatus = 200,
  moveStatus = 204,
}: {
  backlog?: string[]
  backlogStatus?: number
  moveStatus?: number
  jiraPages: unknown[]
  alerts?: unknown[]
  silences?: unknown[]
  jiraStatus?: number
}) => {
  const calls: Call[] = []
  let page = 0
  const fetchImpl = async (
    url: string,
    options: {
      method?: string
      body?: string
      headers?: Record<string, string>
    } = {},
  ) => {
    const call: Call = {
      method: options.method ?? "GET",
      url,
      body: options.body ? JSON.parse(options.body) : undefined,
      headers: options.headers,
    }
    calls.push(call)
    if (url.endsWith("/rest/api/3/search/jql")) {
      return jiraStatus === 200
        ? respond(200, jiraPages[page++])
        : respond(jiraStatus, { errorMessages: ["nope"] })
    }
    if (url.includes("/rest/agile/1.0/board/") && url.includes("/backlog")) {
      return backlogStatus === 200
        ? respond(200, { issues: backlog.map((key) => ({ key })) })
        : respond(backlogStatus, { errorMessages: ["nope"] })
    }
    if (url.includes("/rest/agile/1.0/board/") && url.endsWith("/issue")) {
      return respond(moveStatus, undefined)
    }
    if (url.includes("/api/v2/alerts")) {
      return respond(200, alerts)
    }
    if (url.endsWith("/api/v2/silences") && call.method === "GET") {
      return respond(200, silences)
    }
    if (url.endsWith("/api/v2/silences") && call.method === "POST") {
      return respond(200, { silenceID: "new" })
    }
    if (url.includes("/api/v2/silence/") && call.method === "DELETE") {
      return respond(200, undefined)
    }
    throw new Error(`unexpected call ${call.method} ${url}`)
  }
  return { fetchImpl, calls }
}

describe("run", () => {
  const config = readConfig({
    JIRA_URL: "https://example.atlassian.net",
    JIRA_USER: "bot@example.test",
    JIRA_API_TOKEN: "token",
    JIRA_PROJECT: "HO",
    ALERTMANAGER_URL: "http://alertmanager:9093",
  })

  beforeEach(() => {
    jest.spyOn(console, "log").mockImplementation(() => undefined)
  })

  afterEach(() => {
    jest.restoreAllMocks()
  })

  test("Searches Jira as the bot for In Progress incidents and silences their alerts.", async () => {
    const { fetchImpl, calls } = fakeServices({
      jiraPages: [
        {
          issues: [
            {
              key: "HO-1",
              fields: {
                labels: ["incident", "alertmanager", "alert-fp-aaaa1111"],
              },
            },
          ],
        },
      ],
      alerts: [kubelet, disk],
    })

    await run(config, { fetch: fetchImpl, now })

    const search = calls.find((c) => c.url.endsWith("/rest/api/3/search/jql"))
    expect(search?.method).toEqual("POST")
    expect(search?.headers?.Authorization).toEqual(
      `Basic ${Buffer.from("bot@example.test:token").toString("base64")}`,
    )
    expect((search?.body as { jql: string }).jql).toEqual(
      'project = "HO" AND labels = "incident" AND statusCategory = "In Progress"',
    )

    const created = calls.filter(
      (c) => c.method === "POST" && c.url.endsWith("/api/v2/silences"),
    )
    expect(created).toHaveLength(1)
    expect(created[0].body).toMatchObject({
      createdBy: SILENCE_CREATOR,
      startsAt: new Date(now).toISOString(),
      endsAt: new Date(now + ttlMs).toISOString(),
      matchers: toMatchers(kubeletLabels),
    })
    expect((created[0].body as { comment: string }).comment).toMatch(
      /^HO-1 is In Progress/,
    )
    expect((created[0].body as { id?: string }).id).toBeUndefined()
  })

  test("Follows Jira result pages and skips work items with no fingerprint label.", async () => {
    const { fetchImpl, calls } = fakeServices({
      jiraPages: [
        {
          issues: [
            {
              key: "HO-1",
              fields: { labels: ["incident", "alert-fp-aaaa1111"] },
            },
          ],
          nextPageToken: "page-2",
        },
        {
          issues: [
            { key: "HO-2", fields: { labels: ["incident"] } },
            { key: "HO-3", fields: { labels: ["alert-fp-bbbb2222"] } },
          ],
        },
      ],
      alerts: [kubelet, disk],
    })

    await run(config, { fetch: fetchImpl, now })

    const searches = calls.filter((c) =>
      c.url.endsWith("/rest/api/3/search/jql"),
    )
    expect(searches).toHaveLength(2)
    expect(
      (searches[1].body as { nextPageToken: string }).nextPageToken,
    ).toEqual("page-2")
    const keys = calls
      .filter((c) => c.method === "POST" && c.url.endsWith("/api/v2/silences"))
      .map((c) => (c.body as { comment: string }).comment.split(" ")[0])
    expect(keys).toEqual(["HO-1", "HO-3"])
  })

  test("Deletes the silence of a work item that went back to To Do or Done, and leaves other people's silences alone.", async () => {
    const { fetchImpl, calls } = fakeServices({
      jiraPages: [{ issues: [] }],
      alerts: [kubelet],
      silences: [
        {
          id: "mine",
          createdBy: SILENCE_CREATOR,
          status: { state: "active" },
          comment:
            "HO-1 is In Progress in Jira (acknowledged). Managed by incident-ack-sync, do not edit.",
          matchers: toMatchers(kubeletLabels),
          startsAt: new Date(now - MINUTE).toISOString(),
          endsAt: new Date(now + 10 * MINUTE).toISOString(),
        },
        {
          id: "someone-elses",
          createdBy: "andrew",
          status: { state: "active" },
          comment: "planned maintenance",
          matchers: toMatchers(kubeletLabels),
          startsAt: new Date(now - MINUTE).toISOString(),
          endsAt: new Date(now + 10 * MINUTE).toISOString(),
        },
        {
          id: "already-expired",
          createdBy: SILENCE_CREATOR,
          status: { state: "expired" },
          comment: "HO-7 is In Progress in Jira (acknowledged).",
          matchers: [],
          startsAt: new Date(now - 60 * MINUTE).toISOString(),
          endsAt: new Date(now - 30 * MINUTE).toISOString(),
        },
      ],
    })

    await run(config, { fetch: fetchImpl, now })

    const deleted = calls.filter((c) => c.method === "DELETE").map((c) => c.url)
    expect(deleted).toEqual(["http://alertmanager:9093/api/v2/silence/mine"])
  })

  test("Changes nothing in Alertmanager when Jira cannot be read, so existing silences just run out.", async () => {
    const { fetchImpl, calls } = fakeServices({
      jiraPages: [],
      jiraStatus: 401,
    })

    await expect(run(config, { fetch: fetchImpl, now })).rejects.toThrow(
      "Jira search failed: HTTP 401",
    )

    expect(calls.filter((c) => c.url.includes("alertmanager"))).toEqual([])
  })

  describe("board placement", () => {
    const boardCalls = (calls: Call[]) =>
      calls.filter((c) => c.url.includes("/rest/agile/1.0/"))

    test("Moves open incident work items in the board's backlog onto the board.", async () => {
      const { fetchImpl, calls } = fakeServices({
        jiraPages: [{ issues: [] }],
        backlog: ["HO-10", "HO-11"],
      })

      await run(config, { fetch: fetchImpl, now })

      const [list, move] = boardCalls(calls)
      expect(list.method).toEqual("GET")
      const listUrl = new URL(list.url)
      expect(listUrl.pathname).toEqual("/rest/agile/1.0/board/100/backlog")
      expect(listUrl.searchParams.get("jql")).toEqual(
        'project = "HO" AND labels = "incident" AND statusCategory != "Done"',
      )
      expect(list.headers?.Authorization).toEqual(
        `Basic ${Buffer.from("bot@example.test:token").toString("base64")}`,
      )
      expect(move.method).toEqual("POST")
      expect(move.url).toEqual(
        "https://example.atlassian.net/rest/agile/1.0/board/100/issue",
      )
      expect(move.body).toEqual({ issues: ["HO-10", "HO-11"] })
    })

    test("Leaves the board alone when nothing is in the backlog, so board items and non-incidents are untouched.", async () => {
      const { fetchImpl, calls } = fakeServices({
        jiraPages: [{ issues: [] }],
        backlog: [],
      })

      await run(config, { fetch: fetchImpl, now })

      expect(boardCalls(calls).map((c) => c.method)).toEqual(["GET"])
    })

    test("Uses the configured board id and incident label.", async () => {
      const custom = readConfig({
        JIRA_URL: "https://example.atlassian.net",
        JIRA_USER: "bot@example.test",
        JIRA_API_TOKEN: "token",
        JIRA_PROJECT: "HO",
        JIRA_BOARD_ID: "7",
        INCIDENT_LABEL: "sev",
        ALERTMANAGER_URL: "http://alertmanager:9093",
      })
      const { fetchImpl, calls } = fakeServices({
        jiraPages: [{ issues: [] }],
        backlog: ["HO-10"],
      })

      await run(custom, { fetch: fetchImpl, now })

      const [list, move] = boardCalls(calls)
      expect(new URL(list.url).pathname).toEqual(
        "/rest/agile/1.0/board/7/backlog",
      )
      expect(new URL(list.url).searchParams.get("jql")).toContain(
        'labels = "sev"',
      )
      expect(move.url).toContain("/board/7/issue")
    })

    test("Moves at most 50 work items per request.", async () => {
      const keys = Array.from({ length: 120 }, (_, i) => `HO-${i + 1}`)
      const { fetchImpl, calls } = fakeServices({
        jiraPages: [{ issues: [] }],
        backlog: keys,
      })

      await run(config, { fetch: fetchImpl, now })

      const moves = boardCalls(calls).filter((c) => c.method === "POST")
      expect(
        moves.map((c) => (c.body as { issues: string[] }).issues.length),
      ).toEqual([50, 50, 20])
    })

    test("Tolerates a board API error: still syncs acknowledgements, then fails the run so the alert sees it.", async () => {
      const { fetchImpl, calls } = fakeServices({
        jiraPages: [
          {
            issues: [
              { key: "HO-1", fields: { labels: ["alert-fp-aaaa1111"] } },
            ],
          },
        ],
        alerts: [kubelet],
        backlogStatus: 403,
      })

      await expect(run(config, { fetch: fetchImpl, now })).rejects.toThrow(
        "Jira board backlog failed: HTTP 403",
      )

      expect(
        calls.filter(
          (c) => c.method === "POST" && c.url.endsWith("/api/v2/silences"),
        ),
      ).toHaveLength(1)
    })

    test("Tolerates a failed move and still syncs acknowledgements.", async () => {
      jest.spyOn(console, "error").mockImplementation(() => undefined)
      const { fetchImpl, calls } = fakeServices({
        jiraPages: [{ issues: [] }],
        backlog: ["HO-10"],
        moveStatus: 400,
        silences: [],
      })

      await expect(run(config, { fetch: fetchImpl, now })).rejects.toThrow(
        "Jira move to board failed: HTTP 400",
      )

      expect(calls.some((c) => c.url.endsWith("/rest/api/3/search/jql"))).toBe(
        true,
      )
    })

    test("Still moves incidents when the acknowledgement search fails.", async () => {
      jest.spyOn(console, "error").mockImplementation(() => undefined)
      const { fetchImpl, calls } = fakeServices({
        jiraPages: [],
        jiraStatus: 401,
        backlog: ["HO-10"],
      })

      await expect(run(config, { fetch: fetchImpl, now })).rejects.toThrow(
        "Jira search failed: HTTP 401",
      )

      expect(boardCalls(calls).map((c) => c.method)).toEqual(["GET", "POST"])
    })
  })
})
