#!/usr/bin/env -S yarn exec tsx
// Run FROM A LAPTOP ON THE GUEST NETWORK (macOS). Read-only. Requires nmap.
// Source: https://docs.home.smith-simms.family/wiki/spaces/GRR/pages/200376321/Guest+Device+Streaming
//
// Required env vars:
//   GUEST_SUBNET       e.g. 192.168.30.0/24
//   MAIN_SUBNET        e.g. 192.168.1.0/24
//   GATEWAY_IP         guest network gateway IP
//   MAIN_LAN_DEVICES   comma-separated main-LAN IPs expected to be unreachable (NAS, C4 controller, etc.)
//   RECEIVER_IP        Apple TV / casting box IP
//
// Usage:
//   GUEST_SUBNET=192.168.30.0/24 MAIN_SUBNET=192.168.1.0/24 GATEWAY_IP=192.168.30.1 \
//   MAIN_LAN_DEVICES=192.168.1.10,192.168.1.20 RECEIVER_IP=192.168.30.50 \
//   yarn exec tsx scripts/guest-isolation-test.ts

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
const MAIN_SUBNET = requireEnv("MAIN_SUBNET"); // e.g. 192.168.1.0/24
const GATEWAY_IP = requireEnv("GATEWAY_IP"); // guest network gateway
const MAIN_LAN_DEVICES = requireEnv("MAIN_LAN_DEVICES").split(",").map((ip) => ip.trim()); // comma-separated, e.g. NAS, C4 controller
const RECEIVER_IP = requireEnv("RECEIVER_IP"); // Apple TV / casting box
const GUEST_PREFIX = GUEST_SUBNET.split("/")[0].split(".").slice(0, 3).join("."); // derived from GUEST_SUBNET
// ------------------------------------------------------------------

const GREEN = "\x1b[0;32m";
const RED = "\x1b[0;31m";
const YELLOW = "\x1b[1;33m";
const NC = "\x1b[0m";

const pass = (msg: string) => console.log(`${GREEN}[PASS]${NC} ${msg}`);
const fail = (msg: string) => console.log(`${RED}[FAIL]${NC} ${msg}`);
const warn = (msg: string) => console.log(`${YELLOW}[WARN]${NC} ${msg}`);
const hdr = (title: string) => console.log(`\n=== ${title} ===`);

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

  hdr("1. mDNS discovery (what guests SEE)");
  const services = [
    "_services._dns-sd._udp",
    "_airplay._tcp",
    "_googlecast._tcp",
    "_smb._tcp",
    "_afpovertcp._tcp",
    "_ipp._tcp",
    "_hap._tcp",
  ];
  for (const svc of services) {
    console.log(`--- ${svc} ---`);
    const output = run(`dns-sd -B ${svc} local. & P=$!; sleep 4; kill $P 2>/dev/null`).stdout;
    const filtered = output
      .split("\n")
      .filter((line) => !/^Browsing|^Timestamp|^\s*$/.test(line))
      .join("\n");
    if (filtered) console.log(filtered);
  }
  warn("Ideally only your receiver shows. NAS/printers/HomePods from main LAN = mDNS leak.");

  hdr("2. Guest-subnet sweep (client isolation)");
  const guestScan = run(`nmap -sn "${GUEST_SUBNET}"`).stdout;
  const guestHostsUp = (guestScan.match(/Host is up/g) ?? []).length;
  console.log(`Guest hosts up: ${guestHostsUp}`);
  if (guestHostsUp <= 2) {
    pass("Client isolation likely ON.");
  } else {
    warn(`${guestHostsUp} guests visible — isolation may be OFF.`);
  }

  hdr("3. MAIN-LAN sweep (KEY TEST)");
  const mainScan = run(`nmap -sn "${MAIN_SUBNET}"`).stdout;
  const mainHostsUp = (mainScan.match(/Host is up/g) ?? []).length;
  console.log(`Main-LAN hosts up: ${mainHostsUp}`);
  if (mainHostsUp === 0) {
    pass("Zero main-LAN hosts reachable. Boundary holding.");
  } else {
    fail(`${mainHostsUp} main-LAN hosts reachable — LEAK. Fix guest->LAN block.`);
  }

  hdr("4. Named device probes (expected UNREACHABLE)");
  for (const ip of MAIN_LAN_DEVICES) {
    console.log(`--- ${ip} ---`);
    if (run(`ping -c 1 -t 2 "${ip}"`).code === 0) {
      fail(`${ip} answers ping.`);
    } else {
      pass(`${ip} no ping.`);
    }
    const openPorts = run(`nmap -Pn -p 22,80,443,445,548,8080,8443 "${ip}"`).stdout;
    const openCount = (openPorts.match(/open/g) ?? []).length;
    if (openCount === 0) {
      pass(`${ip} no open ports.`);
    } else {
      fail(`${ip} ${openCount} port(s) open — gap.`);
    }
  }

  hdr("4b. Receiver (expected REACHABLE)");
  if (run(`ping -c 1 -t 2 "${RECEIVER_IP}"`).code === 0) {
    pass(`Receiver ${RECEIVER_IP} reachable (guests can cast).`);
  } else {
    warn(`Receiver ${RECEIVER_IP} unreachable — casting will fail.`);
  }

  hdr("5. Gateway management exposure");
  const gatewayOpen = run(`nmap -Pn -p 22,443,8443 "${GATEWAY_IP}"`)
    .stdout.split("\n")
    .filter((line) => line.includes("open"))
    .join("\n");
  if (!gatewayOpen) {
    pass("Gateway management not exposed.");
  } else {
    fail("Gateway mgmt reachable:");
    console.log(gatewayOpen);
    warn("Allow only DHCP/DNS guest->gateway.");
  }

  console.log("\nRe-run after every UDM change. Valid only when section 0 = PASS.");
}

main();
