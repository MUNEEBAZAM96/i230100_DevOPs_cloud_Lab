import base64
import json
import os
import time

import boto3

s3 = boto3.client("s3")

NOT_FOUND_HTML = (
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Not found</title></head>"
    "<body><h1>404 Not Found</h1><p>That page is not on this CV site.</p></body></html>"
)

ERROR_HTML = (
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Error</title></head>"
    "<body><p>The CV page could not be loaded.</p></body></html>"
)

ROUTES = {
    "/": "index.html",
    "/index.html": "index.html",
    "/style.css": "style.css",
    "/cv.pdf": "cv.pdf",
}

CONTENT_TYPES = {
    "index.html": "text/html; charset=utf-8",
    "style.css": "text/css; charset=utf-8",
    "cv.pdf": "application/pdf",
}


def request_path(event):
    path = "/"
    if isinstance(event, dict):
        path = event.get("rawPath") or event.get("path") or "/"
    path = str(path).split("?", 1)[0]
    if len(path) > 1 and path.endswith("/"):
        path = path[:-1]
    return path or "/"


def object_key(name):
    prefix = os.environ["PREFIX"].strip("/")
    return f"{prefix}/{name}"


def lambda_handler(event, context):
    started = time.perf_counter()
    path = "/"
    status = 500
    try:
        path = request_path(event)
        filename = ROUTES.get(path)
        if filename is None:
            status = 404
            return {
                "statusCode": 404,
                "headers": {"Content-Type": "text/html; charset=utf-8"},
                "body": NOT_FOUND_HTML,
                "isBase64Encoded": False,
            }

        payload = s3.get_object(
            Bucket=os.environ["BUCKET"],
            Key=object_key(filename),
        )["Body"].read()

        headers = {"Content-Type": CONTENT_TYPES[filename]}
        if filename == "index.html":
            body = payload.decode("utf-8").replace(
                "{{HOSTED_ON}}",
                f"Lambda {context.function_name}",
            )
            headers["Cache-Control"] = "max-age=60"
            encoded = False
        elif filename == "cv.pdf":
            body = base64.b64encode(payload).decode("ascii")
            encoded = True
        else:
            body = payload.decode("utf-8")
            encoded = False

        status = 200
        return {
            "statusCode": 200,
            "headers": headers,
            "body": body,
            "isBase64Encoded": encoded,
        }
    except Exception:
        status = 500
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "text/html; charset=utf-8"},
            "body": ERROR_HTML,
            "isBase64Encoded": False,
        }
    finally:
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        function_name = getattr(context, "function_name", "")
        print(
            json.dumps(
                {"fn": function_name, "path": path, "status": status, "ms": elapsed_ms},
                separators=(",", ":"),
            )
        )
