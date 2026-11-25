"""Kết nối Redis dùng chung. Không ping lúc import để app vẫn khởi động được khi thiếu Redis."""
import json
import sys

import redis

from app.config import settings

_FALLBACK_URL = "redis://localhost:6379/0"
_OPTS = dict(decode_responses=True, socket_connect_timeout=1, socket_timeout=2)


def _make_client(url: str) -> redis.Redis:
    url = (url or "").strip()
    if url and "://" not in url:
        url = "redis://" + url  # chấp nhận "host:port" thiếu scheme
    try:
        return redis.from_url(url or _FALLBACK_URL, **_OPTS)
    except ValueError as exc:
        # Cấu hình sai không được làm app sập: /health vẫn 200, /ready trả 503.
        print(json.dumps({"lvl": "ERROR", "event": "invalid_redis_url", "detail": str(exc)}),
              file=sys.stderr, flush=True)
        return redis.from_url(_FALLBACK_URL, **_OPTS)


r = _make_client(settings.redis_url)


def redis_healthy() -> bool:
    try:
        return bool(r.ping())
    except Exception:
        return False
