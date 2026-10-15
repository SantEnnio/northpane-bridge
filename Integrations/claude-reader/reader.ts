import { listSessions, getSessionInfo, getSessionMessages } from "@anthropic-ai/claude-agent-sdk";

// Only local session-file APIs. Never import query(), start Claude, or resume a session.
const version = "0.3.293";
// The SDK owns transcript discovery, compaction and parentUuid chain selection.
// Bound presentation data BEFORE stdout: a single tool result can exceed the pipe.
function presentation(messages: Awaited<ReturnType<typeof getSessionMessages>>, limit: number) {
  let truncated = false;
  let bytesLeft = 600 * 1024;
  const kept = [];
  for (const entry of messages.slice(-limit).reverse()) {
    let charactersLeft = 24_000;
    let nodesLeft = 2_000;
    function clip(value: unknown, depth = 0): unknown {
      if (--nodesLeft < 0 || depth > 8) { truncated = true; return ""; }
      if (typeof value === "string") {
        const text = value.slice(0, charactersLeft);
        charactersLeft -= text.length;
        if (text !== value) truncated = true;
        return text;
      }
      if (Array.isArray(value)) {
        // Hidden reasoning is never part of the conversation presentation.
        const visible = value.filter(v => v?.type !== "thinking" && v?.type !== "redacted_thinking");
        if (visible.length > 100) truncated = true;
        return visible.slice(0, 100).map(v => clip(v, depth + 1));
      }
      if (value && typeof value === "object") {
        const keys = Object.keys(value);
        if (keys.length > 100) truncated = true;
        return Object.fromEntries(keys.slice(0, 100).map(key => [key.slice(0, 128), clip((value as Record<string, unknown>)[key], depth + 1)]));
      }
      return value;
    }
    const item = { uuid: entry.uuid, type: entry.type, message: clip(entry.message) };
    const size = Buffer.byteLength(JSON.stringify(item));
    if (size > bytesLeft) { truncated = true; break; }
    bytesLeft -= size;
    kept.push(item);
  }
  return { messages: kept.reverse(), hasOlder: messages.length > kept.length, truncated };
}
const [directory, id, rawLimit] = process.argv.slice(2);
if (directory === "--version") {
  console.log(JSON.stringify({ sdk: version, runtime: Bun.version }));
} else {
  try {
    const limit = Number(rawLimit);
    if (typeof directory !== "string" || typeof id !== "string" ||
        !Number.isInteger(limit) || limit < 20 || limit > 200 ||
        (id && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))) {
      throw new Error("Invalid request");
    }
    const options = directory ? { dir: directory } : {};
    if (!id) {
      console.log(JSON.stringify({ sessions: await listSessions({ ...options, limit: 50 }) }));
    } else {
      const info = await getSessionInfo(id, options);
      if (!info) console.log(JSON.stringify({ problem: "unreadable" }));
      // Larger ordinary histories still use the official SDK's compaction handling.
      // This is a Host-work bound, separate from the much smaller output budget.
      else if (info.fileSize > 128 * 1024 * 1024) console.log(JSON.stringify({ problem: "outputTooLarge" }));
      else {
        const messages = await getSessionMessages(id, { ...options, includeSystemMessages: true });
        console.log(JSON.stringify(presentation(messages, limit)));
      }
    }
  } catch {
    // Never put transcript contents, paths or SDK exception details on stderr.
    console.log(JSON.stringify({ problem: "unreadable" }));
    process.exitCode = 1;
  }
}
