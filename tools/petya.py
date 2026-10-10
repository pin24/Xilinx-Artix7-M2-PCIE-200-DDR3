#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""petya.py — вызов локального OpenAI-совместимого сервера "Петя" (Swift 1.5).

Возможности:
  python petya.py --effort none|low|medium|high "вопрос"     # уровень размышления
  python petya.py --effort medium --think-budget 80000 --file prompt.txt
  python petya.py --dry-run "вопрос"                          # только показать JSON, НЕ отправлять
  python petya.py --system "..." "вопрос"
  echo "вопрос" | python petya.py

Потребление:
  * reasoning_effort: none|low|medium|high (по умолч. medium). high = максимум думания.
  * reasoning_budget_tokens N: жёсткий лимит думания (гарантирует появление content).
  * max_tokens: ограничивает суммарный вывод (думание+content). Ставим большой, чтобы content не терялся.

Проверка перед запуском: --dry-run печатает итоговый JSON (можно оценить на BadRequest).
Коды: 0 ok, 1 ошибка, 2 badrequest.
"""
import argparse
import json
import sys
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

DEFAULT_URL = "http://127.0.0.1:8080/v1/chat/completions"
DEFAULT_MODEL = "swift-1.5-iq2_xs"
VALID_EFFORT = ("none", "low", "medium", "high")


def build_payload(prompt, system=None, model=DEFAULT_MODEL, effort="medium",
                  max_tokens=100000, think_budget=None, temperature=None):
    msgs = []
    if system:
        msgs.append({"role": "system", "content": system})
    msgs.append({"role": "user", "content": prompt})
    body = {
        "model": model,
        "messages": msgs,
        "stream": False,
        "max_tokens": max_tokens,
    }
    if effort:
        body["reasoning_effort"] = effort
    if think_budget:
        body["reasoning_budget_tokens"] = think_budget
    if temperature is not None:
        body["temperature"] = temperature
    return body


def call(url, body, timeout=1800):
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt", nargs="?", default=None)
    ap.add_argument("--file", default=None)
    ap.add_argument("--system", default=None)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--effort", default="medium", choices=VALID_EFFORT)
    ap.add_argument("--max", type=int, default=100000, dest="max_tokens")
    ap.add_argument("--think-budget", type=int, default=None)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--out", default="petya_content.txt")
    ap.add_argument("--think", action="store_true", help="печатать и reasoning_content")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.file:
        prompt = open(a.file, encoding="utf-8").read()
    elif a.prompt:
        prompt = a.prompt
    else:
        prompt = sys.stdin.read()
    if not prompt.strip():
        print("нет запроса", file=sys.stderr)
        return 1

    body = build_payload(prompt, system=a.system, model=a.model, effort=a.effort,
                         max_tokens=a.max_tokens, think_budget=a.think_budget)

    # проверка перед отправкой
    if a.dry_run:
        print(json.dumps(body, ensure_ascii=False, indent=2))
        return 0
    if a.effort not in VALID_EFFORT:
        print(f"недопустимый effort: {a.effort}", file=sys.stderr)
        return 1

    try:
        d = call(a.url, body, timeout=a.timeout)
    except urllib.error.HTTPError as e:
        txt = e.read().decode("utf-8", "replace")[:500]
        print(f"HTTP {e.code}: {txt}", file=sys.stderr)
        return 2
    except Exception as e:  # noqa
        print(f"PETYA ERROR: {type(e).__name__}: {e}", file=sys.stderr)
        return 1

    ch = d["choices"][0]
    m = ch["message"]
    content = m.get("content") or ""
    reasoning = m.get("reasoning_content") or ""
    open(a.out, "w", encoding="utf-8").write(content)
    if a.think:
        open(a.out.replace(".txt", "_reasoning.txt"), "w", encoding="utf-8").write(reasoning)
        print("=== reasoning ===")
        print(reasoning)
        print("=== content ===")
    print(content if content else f"(content пуст; finish={ch.get('finish_reason')}, think={len(reasoning)})")
    print(f"[finish={ch.get('finish_reason')} usage={d.get('usage')}]", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())