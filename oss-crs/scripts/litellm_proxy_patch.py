"""
usercustomize.py — Monkey-patch litellm.completion to route ALL models
through the oss-crs LiteLLM proxy when OSS_CRS_LLM_API_URL is set.

This file is copied to the venv's site-packages/usercustomize.py by
run_fuzzingbrain.sh so that every Python process in the container
automatically gets the patch.

How it works:
  - Wraps litellm.completion so that every call prepends "openai/" to
    the model name (making litellm use the OpenAI-compatible protocol)
    and injects api_base / api_key pointing at the proxy.
  - Patches google.generativeai so that direct Gemini calls also go
    through litellm → proxy instead of calling the Google API.
"""
import os as _os

_PROXY_URL = _os.environ.get("OSS_CRS_LLM_API_URL")
_PROXY_KEY = open(_os.environ["OSS_CRS_LLM_API_KEY_FILE"]).read().strip() if _os.environ.get("OSS_CRS_LLM_API_KEY_FILE") else _os.environ.get("OSS_CRS_LLM_API_KEY", "")

if _PROXY_URL:
    # ── 1. Patch litellm.completion ──────────────────────────────────
    try:
        import litellm as _litellm

        _original_completion = _litellm.completion

        def _proxy_completion(*args, **kwargs):
            # Normalise: accept model as first positional or keyword arg
            if args:
                model = args[0]
                args = args[1:]
            else:
                model = kwargs.pop("model", None)

            if model and not model.startswith("openai/"):
                model = f"openai/{model}"

            kwargs["model"] = model
            kwargs.setdefault("api_base", _PROXY_URL)
            kwargs.setdefault("api_key", _PROXY_KEY)
            return _original_completion(**kwargs)

        _litellm.completion = _proxy_completion
    except ImportError:
        pass

    # ── 2. Patch google.generativeai so Gemini calls go via litellm ──
    try:
        import google.generativeai as _genai

        class _ProxiedGenerativeModel:
            """Drop-in replacement that routes generate_content through litellm."""

            def __init__(self, model_name, **kwargs):
                self._model = model_name

            def generate_content(self, contents, **kwargs):
                messages = _convert_genai_to_messages(contents)
                return _call_via_litellm(self._model, messages)

            def start_chat(self, history=None, **kwargs):
                return _ProxiedChat(self._model, history or [])

        class _ProxiedChat:
            def __init__(self, model, history):
                self._model = model
                self._history = list(history)
                self.system_instruction = None

            def send_message(self, message, **kwargs):
                messages = []
                if self.system_instruction:
                    messages.append({"role": "system", "content": self.system_instruction})
                for h in self._history:
                    role = "assistant" if h.get("role") == "model" else "user"
                    parts = h.get("parts", [])
                    content = parts[0] if parts else ""
                    messages.append({"role": role, "content": content})
                messages.append({"role": "user", "content": message})
                return _call_via_litellm(self._model, messages)

        class _ProxiedResponse:
            def __init__(self, text):
                self.text = text

        def _convert_genai_to_messages(contents):
            if isinstance(contents, str):
                return [{"role": "user", "content": contents}]
            if isinstance(contents, list):
                messages = []
                for item in contents:
                    if isinstance(item, dict):
                        role = "assistant" if item.get("role") == "model" else "user"
                        parts = item.get("parts", [])
                        content = parts[0] if parts else str(item)
                        messages.append({"role": role, "content": content})
                    else:
                        messages.append({"role": "user", "content": str(item)})
                return messages
            return [{"role": "user", "content": str(contents)}]

        def _call_via_litellm(model, messages):
            resp = _litellm.completion(model=model, messages=messages,
                                       temperature=0.7, max_tokens=8192)
            text = resp["choices"][0]["message"]["content"]
            return _ProxiedResponse(text)

        # Replace the real GenerativeModel with our proxy
        _genai.GenerativeModel = _ProxiedGenerativeModel
        # Make configure() a no-op so existing code doesn't break
        _genai.configure = lambda **kw: None

    except ImportError:
        pass
