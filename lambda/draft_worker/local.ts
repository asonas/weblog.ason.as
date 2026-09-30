import { seedPiece } from "./reconstruct.js";
import { reconstructStoredDraft } from "./storedInput.js";

// Local process transport only; production invocation requires an authenticated internal path.
let input = "";
for await (const chunk of process.stdin) input += chunk;
const job = JSON.parse(input);
process.stdout.write(
  JSON.stringify(
    job.operation === "seed_piece"
      ? seedPiece(job.piece_id, job.body)
      : reconstructStoredDraft(job),
  ),
);
