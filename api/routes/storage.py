# =====================================================================
# Storage API
# Path: api/routes/storage.py
# =====================================================================

from fastapi import APIRouter, UploadFile

from api.deps import STORAGE

router = APIRouter()


@router.post("/upload")
async def upload(bucket: str, object: str, file: UploadFile):
    data = await file.read()
    resp = STORAGE.upload(bucket, object, data)
    return resp


@router.get("/download")
def download(bucket: str, object: str):
    data = STORAGE.download(bucket, object)
    return {"object": object, "data": data}


@router.get("/list")
def list_objects(bucket: str):
    return STORAGE.list(bucket)
