export type ProofreadingMessage = {
  ruleId: string;
  message: string;
  line: number;
  range: readonly [number, number];
};

export type ProofreadingResponse = {
  messages: ProofreadingMessage[];
};
