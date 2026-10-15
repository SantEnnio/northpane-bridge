import { listSessions, getSessionInfo, getSessionMessages } from "@anthropic-ai/claude-agent-sdk";

// Only local session-file APIs. Never import query(), start Claude, or resume a session.
const version = "0.3.293";
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
      else if (info.fileSize > 16 * 1024 * 1024) console.log(JSON.stringify({ problem: "outputTooLarge" }));
      else {
        const messages = await getSessionMessages(id, { ...options, includeSystemMessages: true });
        console.log(JSON.stringify({ messages: messages.slice(-limit), hasOlder: messages.length > limit }));
      }
    }
  } catch {
    // Never put transcript contents, paths or SDK exception details on stderr.
    console.log(JSON.stringify({ problem: "unreadable" }));
    process.exitCode = 1;
  }
}
