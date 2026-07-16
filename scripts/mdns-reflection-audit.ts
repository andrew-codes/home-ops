#!/usr/bin/env -S yarn exec tsx
// Run FROM A LAPTOP ON THE GUEST NETWORK (macOS), AFTER enabling mDNS reflection.
// JOB 1: inventory what reflection exposes to guests.
// JOB 2: prove guests can reach ONLY the Apple TV.
// Read-only: observes/probes, changes nothing. Requires: nmap (brew install nmap), dns-sd.
// Source: https://docs.home.smith-simms.family/wiki/spaces/GRR/pages/200376321/Guest+Device+Streaming
//
// Required env vars:
//   GUEST_SUBNET   e.g. 192.168.30.0/24
//   APPLE_TV_IP    Apple TV's primary-LAN IP
//
// Optional env vars:
//   APPLE_TV_ALLOWED_PORTS   default: 7000,7100,49152-65535,5000,3689
//
// Usage:
//   GUEST_SUBNET=192.168.30.0/24 APPLE_TV_IP=192.168.30.50 \
//   yarn exec tsx scripts/mdns-reflection-audit.ts

import { throwIfError } from "@ha/shell-utils";
import sh from "shelljs";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing required env var: ${name}`);
    process.exit(1);
  }
  return value;
}

// ---- CONFIGURE VIA ENV VARS (see script header / Confluence page) ----
const GUEST_SUBNET = requireEnv("GUEST_SUBNET"); // e.g. 192.168.30.0/24
const APPLE_TV_IP = requireEnv("APPLE_TV_IP"); // Apple TV's primary-LAN IP
const GUEST_PREFIX = GUEST_SUBNET.split("/")[0].split(".").slice(0, 3).join("."); // derived from GUEST_SUBNET
const APPLE_TV_ALLOWED_PORTS = process.env.APPLE_TV_ALLOWED_PORTS ?? "7000,7100,49152-65535,5000,3689";
const BROWSE_SECS = 6;
const SERVICES = [
  "_airplay._tcp",
  "_raop._tcp",
  "_googlecast._tcp",
  "_smb._tcp",
  "_afpovertcp._tcp",
  "_ipp._tcp",
  "_printer._tcp",
  "_hap._tcp",
  "_ssh._tcp",
  "_device-info._tcp",
  "_spotify-connect._tcp",
  "_sonos._tcp",
  "_daap._tcp",
  "_rfb._tcp",
  "_http._tcp",
];
const GREEN = "\x1b[0;32m";
const RED = "\x1b[0;31m";
const YELLOW = "\x1b[1;33m";
const BLUE = "\x1b[0;34m";
const NC = "\x1b[0m";

const pass = (msg: string) => console.log(`${GREEN}[PASS]${NC} ${msg}`);
const fail = (msg: string) => console.log(`${RED}[FAIL]${NC} ${msg}`);
const warn = (msg: string) => console.log(`${YELLOW}[WARN]${NC} ${msg}`);
const info = (msg: string) => console.log(`${BLUE}[INFO]${NC} ${msg}`);
const hdr = (title: string) => {
  console.log("\n===================================================");
  console.log(` ${title}`);
  console.log("===================================================");
};

function run(command: string): sh.ShellString {
  return sh.exec(command, { silent: true });
}

async function commandExists(command: string): Promise<boolean> {
  try {
    await throwIfError(sh.exec(`command -v ${command}`, { silent: true }));
    return true;
  } catch {
    return false;
  }
}

function getGuestSubnetIp(): string | undefined {
  for (const iface of ["en0", "en1"]) {
    const result = run(`ipconfig getifaddr ${iface}`);
    const ip = result.stdout.trim();
    if (result.code === 0 && ip) return ip;
  }
  return undefined;
}

function browseInstances(svc: string): string[] {
  const output = run(`dns-sd -B ${svc} local. & BPID=$!; sleep ${BROWSE_SECS}; kill $BPID 2>/dev/null`).stdout;
  const instances = new Set<string>();
  for (const line of output.split("\n")) {
    if (!line.includes(svc) || !line.includes("Add")) continue;
    const fields = line.trim().split(/\s+/);
    const instance = fields.slice(6).join(" ").trimEnd();
    if (instance) instances.add(instance);
  }
  return [...instances].sort();
}

function resolveInstance(instance: string, svc: string): { host?: string; ip?: string; port?: string; txt?: string } {
  const res = run(`dns-sd -L "${instance}" ${svc} local. & LPID=$!; sleep 3; kill $LPID 2>/dev/null`).stdout;
  const hpMatch = res.match(/can be reached at ([^\s]+):(\d+)/);
  const host = hpMatch?.[1];
  const port = hpMatch?.[2];
  const txtMatches = [...res.matchAll(/\b[a-zA-Z0-9_-]+=[^\s]*/g)].map((m) => m[0]);
  const txt = txtMatches.join(" ");

  let ip: string | undefined;
  if (host) {
    const gRes = run(`dns-sd -Gv4 ${host} & GPID=$!; sleep 2; kill $GPID 2>/dev/null`).stdout;
    ip = gRes.match(/\b(?:\d{1,3}\.){3}\d{1,3}\b/)?.[0];
  }
  return { host, ip, port, txt };
}

async function main() {
  if (!(await commandExists("nmap"))) {
    console.log("nmap not found. Install: brew install nmap");
    process.exit(1);
  }

  hdr("0. On guest subnet?");
  const myIp = getGuestSubnetIp();
  console.log(`IP: ${myIp ?? "unknown"}`);
  if (myIp?.startsWith(`${GUEST_PREFIX}.`)) {
    pass("On guest subnet.");
  } else {
    warn(`NOT on ${GUEST_PREFIX}.x — results meaningless.`);
  }

  hdr("JOB 1 — What mDNS reflection exposes");
  const exposedIps = new Set<string>();
  for (const svc of SERVICES) {
    const instances = browseInstances(svc);
    if (instances.length === 0) continue;
    console.log(`\n${BLUE}### ${svc}${NC}`);
    for (const inst of instances) {
      const { host, ip, port, txt } = resolveInstance(inst, svc);
      console.log(`  • ${inst}`);
      console.log(`      host=${host ?? "?"} ip=${ip ?? "?"} port=${port ?? "?"}`);
      if (txt) console.log(`      txt: ${txt}`);
      if (ip) exposedIps.add(ip);
    }
  }
  const sortedIps = [...exposedIps].sort();
  console.log();
  info(`${sortedIps.length} device IP(s) exposed to guests:`);
  for (const ip of sortedIps) console.log(`    ${ip}`);

  hdr("JOB 2 — Containment: only Apple TV reachable?");
  console.log(`--- Apple TV (${APPLE_TV_IP}): expected REACHABLE ---`);
  const atvOpen = run(`nmap -Pn -p ${APPLE_TV_ALLOWED_PORTS} "${APPLE_TV_IP}"`)
    .stdout.split("\n")
    .filter((line) => line.includes("open"))
    .join("\n");
  if (atvOpen) {
    pass("Apple TV reachable:");
    console.log(
      atvOpen
        .split("\n")
        .map((line) => `      ${line}`)
        .join("\n"),
    );
  } else {
    warn("Apple TV no open AirPlay ports — casting may fail.");
  }

  console.log("\n--- All others: expected UNREACHABLE ---");
  let leaks = 0;
  for (const ip of sortedIps) {
    if (ip === APPLE_TV_IP || ip === myIp) continue;
    const pinged = run(`ping -c 1 -t 2 "${ip}"`).code === 0;
    const openPorts = run(`nmap -Pn --host-timeout 15s -p 22,80,443,445,548,631,3689,5000,8080,8443 "${ip}"`)
      .stdout.split("\n")
      .filter((line) => line.includes("open"))
      .join("\n");
    if (pinged || openPorts) {
      fail(`${ip} REACHABLE — LEAK.`);
      if (openPorts) {
        console.log(
          openPorts
            .split("\n")
            .map((line) => `      ${line}`)
            .join("\n"),
        );
      }
      leaks += 1;
    } else {
      pass(`${ip} unreachable (discovery-only).`);
    }
  }

  hdr("VERDICT");
  if (leaks === 0) {
    pass(`CONTAINED: guests see ${sortedIps.length} device(s), can only reach Apple TV.`);
  } else {
    fail(`${leaks} leak(s) beyond Apple TV — firewall not containing.`);
  }
}

main();
