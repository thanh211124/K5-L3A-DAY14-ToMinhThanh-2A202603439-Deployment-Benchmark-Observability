"""API Key authentication: header X-API-Key phải trùng AGENT_API_KEY, sai/thiếu → 401."""
import hmac

from fastapi import HTTPException, Security
from fastapi.security import APIKeyHeader

from app.config import settings

_header = APIKeyHeader(name="X-API-Key", auto_error=False)


def verify_api_key(api_key: str | None = Security(_header)) -> str:
    expected = settings.agent_api_key
    if not api_key or not expected or not hmac.compare_digest(api_key, expected):
        raise HTTPException(
            status_code=401,
            detail="Invalid or missing API key",
            headers={"WWW-Authenticate": "ApiKey"},
        )
    return api_key
