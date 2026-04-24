from fastapi import APIRouter

from app.api import captures, health

api_router = APIRouter()
api_router.include_router(health.router, tags=["health"])
api_router.include_router(captures.router, prefix="/captures", tags=["captures"])
