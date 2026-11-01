# Hermes Agent

[Hermes Agent](https://hermes-agent.nousresearch.com/) (Nous Research) can use this server as a custom endpoint. The
server is OpenAI-compatible, so no recipe change is needed. The Hermes setup on this page was written by
[Steve Darlow (@kerpopule)](https://github.com/kerpopule), who authored it in PR #52 of the GLM-5.3-Flash recipe, from
which this page is taken.

## Hermes custom endpoint

Use `hermes model`, choose Custom endpoint, and point it at the TensorFold API. Equivalent model settings in the
selected profile's `config.yaml`:

```yaml
model:
  provider: custom
  base_url: http://127.0.0.1:8888/v1
  default: DeepSeek-V4.1-Flash-1017
  context_length: 1048576
```

`default` is `SERVED_NAME` (`DeepSeek-V4.1-Flash-1017` unless changed). Verify `/v1/models` and the model field of actual
replies rather than trusting a requested alias. Keep the endpoint loopback or private (`HOST=127.0.0.1`); an
unauthenticated OpenAI-compatible API must not be exposed publicly. The context value is configured capacity, not a
full-window stress qualification. Current Hermes guidance:
https://hermes-agent.nousresearch.com/docs/integrations/providers/.

## Timings

Steve Darlow's synthetic timing harness (`tools/hermes_benchmark.py` in the GLM-5.3-Flash recipe) is not here: it reads
cumulative counters (`completion_tokens_total`, `decode_seconds_total`, the draft counts) from the Python server's `/health`,
and the native server's `/health` carries none of them. Each reply's `tensorfold` block (`tokens_per_second`,
`prefill_seconds`, `time_to_first_token`, the draft counters) has the per-request figures.
