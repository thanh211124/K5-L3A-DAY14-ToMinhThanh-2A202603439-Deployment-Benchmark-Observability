"""Cost guard: cộng dồn chi phí LLM trong Redis, vượt budget → 402."""
from datetime import datetime, timezone

import redis
from fastapi import HTTPException

from app.config import settings
from app.redis_client import r

# Giá USD / 1K tokens (tham khảo gpt-4o-mini)
PRICE_INPUT_PER_1K = 0.00015
PRICE_OUTPUT_PER_1K = 0.0006


def _keys() -> tuple[str, str]:
    now = datetime.now(timezone.utc)
    return f"cost:day:{now:%Y-%m-%d}", f"cost:month:{now:%Y-%m}"


def check_budget() -> None:
    day_key, month_key = _keys()
    try:
        day = float(r.get(day_key) or 0)
        month = float(r.get(month_key) or 0)
    except redis.RedisError:
        raise HTTPException(status_code=503, detail="Cost guard unavailable")
    if day >= settings.daily_budget_usd or month >= settings.monthly_budget_usd:
        raise HTTPException(status_code=402, detail="Budget exceeded")


def record_cost(input_tokens: int, output_tokens: int) -> float:
    cost = (input_tokens / 1000) * PRICE_INPUT_PER_1K + (output_tokens / 1000) * PRICE_OUTPUT_PER_1K
    day_key, month_key = _keys()
    try:
        pipe = r.pipeline()
        pipe.incrbyfloat(day_key, cost)
        pipe.expire(day_key, 2 * 86400)
        pipe.incrbyfloat(month_key, cost)
        pipe.expire(month_key, 32 * 86400)
        pipe.execute()
    except redis.RedisError:
        pass  # request đã phục vụ xong; không làm hỏng response vì lỗi ghi chi phí
    return cost
