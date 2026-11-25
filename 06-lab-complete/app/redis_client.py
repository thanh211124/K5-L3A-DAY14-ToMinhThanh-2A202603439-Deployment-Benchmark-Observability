"""Kết nối Redis dùng chung. Không ping lúc import để app vẫn khởi động được khi thiếu Redis."""
import redis

from app.config import settings

r = redis.from_url(
    settings.redis_url,
    decode_responses=True,
    socket_connect_timeout=1,
    socket_timeout=2,
)


def redis_healthy() -> bool:
    try:
        return bool(r.ping())
    except Exception:
        return False
