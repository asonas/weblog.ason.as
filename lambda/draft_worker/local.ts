import { reconstructStoredDraft } from "./storedInput.js";

// Local process transport only; production invocation requires an authenticated internal path.
let input = "";
for await (const chunk of process.stdin) input += chunk;
process.stdout.write(JSON.stringify(reconstructStoredDraft(JSON.parse(input))));
