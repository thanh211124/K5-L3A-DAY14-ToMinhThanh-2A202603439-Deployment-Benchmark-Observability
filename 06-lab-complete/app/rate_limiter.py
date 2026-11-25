"""Sliding-window rate limit theo API key, state lưu trong Redis (sorted set)."""
import hashlib
import time
import uuid

import redis
from fastapi import HTTPException

from app.config import settings
from app.redis_client import r

WINDOW_SECONDS = 60


def check_rate_limit(key: str) -> None:
    rk = "rate:" + hashlib.sha256(key.encode()).hexdigest()[:16]
    now = time.time()
    try:
        pipe = r.pipeline()
        pipe.zremrangebyscore(rk, 0, now - WINDOW_SECONDS)
        pipe.zcard(rk)
        _, count = pipe.execute()
        if count >= settings.rate_limit_per_minute:
            oldest = r.zrange(rk, 0, 0, withscores=True)
            retry = WINDOW_SECONDS
            if oldest:
                retry = max(1, int(oldest[0][1] + WINDOW_SECONDS - now) + 1)
            raise HTTPException(
                status_code=429,
                detail="Rate limit exceeded",
                headers={"Retry-After": str(retry)},
            )
        pipe = r.pipeline()
        pipe.zadd(rk, {f"{now}:{uuid.uuid4().hex[:8]}": now})
        pipe.expire(rk, WINDOW_SECONDS + 5)
        pipe.execute()
    except redis.RedisError:
        raise HTTPException(status_code=503, detail="Rate limiter unavailable")
