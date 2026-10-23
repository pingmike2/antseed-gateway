// 复刻 @deepseek-ai/dsh-llm-deepseek 的错误分类:providerError() / isQuotaExceededError() / failureMessage()
const isQuotaExceededError = (detail) =>
  /\binsufficient[\s_-]+(?:quota|balance|credits?)\b/i.test(String(detail ?? ""));
const isAuthError = (d) => /\b(invalid|missing|expired)[\s_-]+(?:api[\s_-]*key|token)\b/i.test(String(d ?? ""));

function providerError(status, body) {
  const err = (body && body.error) || {};
  const type = err.type || "";
  const detail = [type, err.code, err.message, err.param].filter(Boolean).join(" | ");
  let code;
  if (status === 401 || status === 403 || ["authentication_error", "permission_error"].includes(type)) code = "AUTH";
  else if (isQuotaExceededError(detail) || status === 402) code = "QUOTA";
  else if (status === 429) code = "RATE_LIMIT";
  else if (status >= 500) code = "UPSTREAM";
  else code = "INVALID_REQUEST";
  return { code, detail, message: err.message };
}

function failureMessage(e) {
  switch (e.code) {
    case "AUTH": return "鉴权失败:" + e.message;
    case "QUOTA": return "当前请求的额度已用尽";
    case "RATE_LIMIT": return "请求过于频繁,请稍后重试";
    case "UPSTREAM": return "上游服务异常";
    default: return String(e.message || "").slice(0, 160);
  }
}

const cases = {
  "v2.0.7 回包 (402 + insufficient_quota)": [402, { error: { message: "insufficient_quota: 对端要押金", type: "insufficient_quota" } }],
  "上游原始 402 (antseed_buyer_fault/insufficient_deposits)": [402, { error: { message: "You are out of AntSeed credits for this request.", type: "api_error", code: "antseed_buyer_fault", param: "insufficient_deposits" } }],
  "v2.0.8 回包 (400 + invalid_request_error/model_requires_deposit)": [400, { error: { message: "对端要押金(insufficient_deposits):这个模型只挂了极少数 $0 peer,本次请求被派到了收费 peer,而本机 AntSeed 押金为 0。改用 auto 或其它免费模型;要用它就先 antseed buyer deposit <金额>", type: "invalid_request_error", code: "model_requires_deposit", param: "deposits" } }],
};

for (const [name, [status, body]] of Object.entries(cases)) {
  const e = providerError(status, body);
  console.log(`${name}\n  → code=${e.code}  UI: ${failureMessage(e)}\n`);
}
