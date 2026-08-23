/**
 * KEL-99 Bun client for the current persistent Keld app-link.
 *
 * `Run-KipcEcho.ps1` copies the current Keld template's `kipc.ts` beside this
 * file, so `AppLinkSession` is the shipping wire-exact Bun client. There is
 * one authenticated HELLO, then exactly 10,000 sequential Call/Reply pairs.
 * The only timed interval is `session.echo`: request encode, framed write,
 * host dispatch, framed reply, and response decode.
 */
import { AppLinkSession, encodeEchoRequest } from "./kipc";

const CALLS = 10_000;
const WARMUP_CALLS = 1_000;
const REQUEST = Object.freeze({ message: "keld-99-persistent-echo", count: 99 });
const RESULT_MARKER = "KELD-99-RESULT:";
const EXPECTED_FAILURE_MARKER = "KELD-99-EXPECTED-FAIL:";

type Mode = "cold" | "warm";
type Fault = "none" | "bad-token" | "wrong-response";

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function readMode(): Mode {
  const value = requiredEnvironment("KELD_BENCH_MODE");
  if (value === "cold" || value === "warm") return value;
  throw new Error(`KELD_BENCH_MODE must be cold or warm, got ${JSON.stringify(value)}`);
}

function readFault(): Fault {
  const value = process.env.KELD_BENCH_FAULT ?? "none";
  if (value === "none" || value === "bad-token" || value === "wrong-response") return value;
  throw new Error(`unsupported KELD_BENCH_FAULT ${JSON.stringify(value)}`);
}

function makeInvalidTokenLink(link: string): string {
  const last = link.at(-1);
  if (!last) throw new Error("KELD_APP_LINK is empty");
  return `${link.slice(0, -1)}${last === "0" ? "1" : "0"}`;
}

function assertEcho(
  response: { message: string; count: number },
  expected: { message: string; count: number },
  call: number,
): void {
  if (response.message !== expected.message || response.count !== expected.count) {
    throw new Error(
      `echo mismatch at call ${call}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(response)}`,
    );
  }
}

function checkedDurationNs(start: number, end: number, call: number): number {
  const duration = end - start;
  if (!Number.isSafeInteger(duration) || duration < 0) {
    throw new Error(`invalid Bun.nanoseconds duration at call ${call}: ${duration}`);
  }
  return duration;
}

const mode = readMode();
const fault = readFault();
const encodedRequestBytes = encodeEchoRequest(REQUEST).length;
if (encodedRequestBytes > 128) {
  throw new Error(`KEL-99 request must remain bounded at <=128 encoded bytes, got ${encodedRequestBytes}`);
}

let session: AppLinkSession | undefined;
try {
  const suppliedLink = requiredEnvironment("KELD_APP_LINK");
  const link = fault === "bad-token" ? makeInvalidTokenLink(suppliedLink) : suppliedLink;
  session = await AppLinkSession.connect(link);

  const expected =
    fault === "wrong-response"
      ? { message: REQUEST.message, count: REQUEST.count + 1 }
      : REQUEST;
  const warmupCalls = mode === "warm" ? WARMUP_CALLS : 0;
  for (let call = 1; call <= warmupCalls; call += 1) {
    assertEcho(await session.echo(REQUEST), expected, call);
  }

  const durationsNs: number[] = [];
  for (let call = 1; call <= CALLS; call += 1) {
    const start = Bun.nanoseconds();
    const response = await session.echo(REQUEST);
    const end = Bun.nanoseconds();
    assertEcho(response, expected, call);
    durationsNs.push(checkedDurationNs(start, end, call));
  }

  console.log(
    `${RESULT_MARKER}${JSON.stringify({
      schema_version: 1,
      mode,
      clock: "Bun.nanoseconds",
      timed_interval: "immediately before await session.echo through decoded Reply validation",
      calls: CALLS,
      warmup_calls: warmupCalls,
      encoded_request_bytes: encodedRequestBytes,
      encoded_reply_bytes: encodedRequestBytes,
      frame_header_bytes: 16,
      request: REQUEST,
      bun_version: Bun.version,
      deltas_ns: durationsNs,
    })}`,
  );
} catch (error) {
  const detail = error instanceof Error ? error.message : String(error);
  if (fault !== "none") {
    console.log(`${EXPECTED_FAILURE_MARKER}${JSON.stringify({ fault, detail })}`);
  } else {
    console.error(`KELD-99 client failure: ${detail}`);
    process.exitCode = 1;
  }
} finally {
  session?.close();
}
