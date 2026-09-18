/**
 * KEL-90 Linux Bun client over Keld's shipping AppLinkSession.
 *
 * kipc.ts and kipc-transport.ts are exact bytes from the pinned Keld revision.
 * Only this file adds benchmark timing and raw-evidence output.
 */
import { AppLinkSession, encodeEchoRequest, type EchoRequest } from "./kipc.ts";

const RESULT_MARKER = "KELD-90-BUN-IPC-RESULT";
const EXPECTED_FAILURE_MARKER = "KELD-90-BUN-IPC-EXPECTED-FAIL";
const WARMUP_CALLS = 1_000;

type Tier = "small" | "representative";
type Fault = "none" | "bad-token" | "wrong-response";
type Mode = "fresh-process" | "warm-cache";

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function readPositiveInteger(name: string, max: number): number {
  const raw = requiredEnvironment(name);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1 || value > max) {
    throw new Error(`${name} must be an integer in [1, ${max}], got ${JSON.stringify(raw)}`);
  }
  return value;
}
function readTier(): Tier {
  const value = requiredEnvironment("KELD_BENCH_TIER");
  if (value === "small" || value === "representative") return value;
  throw new Error(
    `KELD_BENCH_TIER must be small or representative, got ${JSON.stringify(value)}`,
  );
}

function readFault(): Fault {
  const value = process.env.KELD_BENCH_FAULT ?? "none";
  if (value === "none" || value === "bad-token" || value === "wrong-response") return value;
  throw new Error(`unsupported KELD_BENCH_FAULT ${JSON.stringify(value)}`);
}

function readMode(): Mode {
  const value = requiredEnvironment("KELD_BENCH_MODE");
  if (value === "fresh-process" || value === "warm-cache") return value;
  throw new Error(`KELD_BENCH_MODE must be fresh-process or warm-cache, got ${JSON.stringify(value)}`);
}

function makeInvalidTokenLink(link: string): string {
  const last = link.at(-1);
  if (!last) throw new Error("KELD_APP_LINK is empty");
  return `${link.slice(0, -1)}${last === "0" ? "1" : "0"}`;
}

function requestForTier(tier: Tier): { request: EchoRequest; payloadBytes: number } {
  if (tier === "small") {
    const request = { message: "kipc", count: 3 };
    const payloadBytes = encodeEchoRequest(request).length;
    if (payloadBytes !== 6) {
      throw new Error(`small tier drifted from 6 encoded bytes to ${payloadBytes}`);
    }
    return { request, payloadBytes };
  }
  const target = 1024;
  let low = 0;
  let high = 4096;
  while (low <= high) {
    const mid = Math.floor((low + high) / 2);
    const request = { message: "R".repeat(mid), count: 0 };
    const encoded = encodeEchoRequest(request).length;
    if (encoded === target) return { request, payloadBytes: encoded };
    if (encoded < target) low = mid + 1;
    else high = mid - 1;
  }
  throw new Error("no exact 1,024-byte representative EchoRequest exists for the pinned codec");
}

function assertEcho(response: EchoRequest, expected: EchoRequest, call: number): void {
  if (response.message !== expected.message || response.count !== expected.count) {
    throw new Error(
      `echo mismatch at call ${call}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(response)}`,
    );
  }
}

function checkedDurationNs(start: number, end: number, label: string): number {
  const duration = end - start;
  if (!Number.isSafeInteger(duration) || duration < 0) {
    throw new Error(`invalid Bun.nanoseconds duration for ${label}: ${duration}`);
  }
  return duration;
}
const tier = readTier();
const calls = readPositiveInteger("KELD_BENCH_CALLS", 1_000_000);
const fault = readFault();
const mode = readMode();
const outPath = requiredEnvironment("KELD_BENCH_OUT");
const keldSha = requiredEnvironment("KELD_BENCH_KELD_SHA");
if (!/^[0-9a-f]{40}$/.test(keldSha)) {
  throw new Error("KELD_BENCH_KELD_SHA must be a lowercase 40-hex commit");
}
const { request, payloadBytes } = requestForTier(tier);

if (await Bun.file(outPath).exists()) {
  throw new Error(`refusing to overwrite benchmark output ${outPath}`);
}

let session: AppLinkSession | undefined;
try {
  const suppliedLink = requiredEnvironment("KELD_APP_LINK");
  const link = fault === "bad-token" ? makeInvalidTokenLink(suppliedLink) : suppliedLink;

  const handshakeStart = Bun.nanoseconds();
  session = await AppLinkSession.connect(link);
  const handshakeNs = checkedDurationNs(handshakeStart, Bun.nanoseconds(), "HELLO");

  const expected =
    fault === "wrong-response"
      ? { message: request.message, count: request.count + 1 }
      : request;

  const warmupCalls = mode === "warm-cache" ? WARMUP_CALLS : 0;
  for (let call = 1; call <= warmupCalls; call += 1) {
    assertEcho(await session.echo(request), expected, call);
  }

  const deltasNs: number[] = [];
  for (let call = 1; call <= calls; call += 1) {
    const start = Bun.nanoseconds();
    const response = await session.echo(request);
    const end = Bun.nanoseconds();
    assertEcho(response, expected, call);
    deltasNs.push(checkedDurationNs(start, end, `call ${call}`));
  }

  const document = {
    schema_version: 1,
    fixture: "kel90-linux-bun-kipc-echo",
    keld_sha: keldSha,
    clock: "Bun.nanoseconds around shipping AppLinkSession.echo",
    timed_interval: "before session.echo through decoded EchoResponse return",
    cache_state: mode,
    tier,
    payload_bytes: payloadBytes,
    handshake_ns: handshakeNs,
    handshake_included_in_deltas: false,
    warmup_calls: warmupCalls,
    calls_requested: calls,
    calls_timed: deltasNs.length,
    bun_version: Bun.version,
    bun_revision: Bun.revision,
    deltas_ns: deltasNs,
  };
  await Bun.write(outPath, JSON.stringify(document));
  console.log(RESULT_MARKER);

  // Product sessions stay alive until the host owns teardown.
  await new Promise<never>(() => {});
} catch (error) {
  const detail = error instanceof Error ? error.message : String(error);
  if (fault !== "none") {
    console.log(`${EXPECTED_FAILURE_MARKER}:${JSON.stringify({ fault, detail })}`);
  } else {
    console.error(`KELD-90 Bun IPC client failure: ${detail}`);
    process.exitCode = 1;
  }
} finally {
  session?.close();
}
