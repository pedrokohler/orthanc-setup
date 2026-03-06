#!/usr/bin/env node
"use strict";

const http = require("node:http");

const PROXY_PORT = Number(process.env.PROXY_PORT || 8050);
const TARGET_HOST = process.env.TARGET_HOST || "127.0.0.1";
const TARGET_PORT = Number(process.env.TARGET_PORT || 8042);
const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN || "http://localhost:3000";
const ALLOW_CREDENTIALS = (process.env.ALLOW_CREDENTIALS || "true") === "true";

const ALLOWED_METHODS = "GET,POST,PUT,PATCH,DELETE,OPTIONS";
const FALLBACK_ALLOWED_HEADERS = "Accept,Authorization,Content-Type,Origin";

function pickAllowedOrigin(origin) {
  if (!origin) {
    return ALLOWED_ORIGIN;
  }

  if (ALLOWED_ORIGIN === "*") {
    return "*";
  }

  return origin === ALLOWED_ORIGIN ? origin : ALLOWED_ORIGIN;
}

function applyCorsHeaders(req, res) {
  const origin = req.headers.origin;
  const requestedHeaders = req.headers["access-control-request-headers"];
  const allowedHeaders =
    typeof requestedHeaders === "string" && requestedHeaders.trim().length > 0
      ? requestedHeaders
      : FALLBACK_ALLOWED_HEADERS;

  res.setHeader("Access-Control-Allow-Origin", pickAllowedOrigin(origin));
  res.setHeader("Access-Control-Allow-Methods", ALLOWED_METHODS);
  res.setHeader("Access-Control-Allow-Headers", allowedHeaders);
  res.setHeader("Access-Control-Max-Age", "86400");
  res.setHeader("Vary", "Origin, Access-Control-Request-Headers");

  if (ALLOW_CREDENTIALS) {
    res.setHeader("Access-Control-Allow-Credentials", "true");
  }
}

function sanitizeUpstreamHeaders(headers) {
  const copy = { ...headers };
  delete copy.host;
  delete copy.connection;
  delete copy["content-length"];
  return copy;
}

function shouldRewriteAcceptHeader(urlPath, method) {
  if (method !== "GET" || typeof urlPath !== "string") {
    return false;
  }

  // Match WADO-RS retrieve instance:
  // /dicom-web/studies/{}/series/{}/instances/{}
  // but avoid frames/bulk/metadata sub-resources.
  const isRetrieveInstanceRoute =
    /^\/dicom-web\/studies\/[^/]+\/series\/[^/]+\/instances\/[^/]+$/.test(urlPath);

  return isRetrieveInstanceRoute;
}

function maybeRewriteAcceptHeader(headers, urlPath, method) {
  const copy = { ...headers };
  const accept = copy.accept;

  if (
    shouldRewriteAcceptHeader(urlPath, method) &&
    typeof accept === "string" &&
    /multipart\/related/i.test(accept) &&
    /application\/octet-stream/i.test(accept)
  ) {
    copy.accept = accept.replace(/application\/octet-stream/gi, "application/dicom");
  }

  return copy;
}

function rewriteStudiesIncludeField(urlPath, method) {
  if (method !== "GET" || typeof urlPath !== "string") {
    return urlPath;
  }

  const parsed = new URL(urlPath, "http://proxy.local");
  if (parsed.pathname !== "/dicom-web/studies") {
    return urlPath;
  }

  const includeField = parsed.searchParams.get("includefield");
  if (!includeField) {
    return urlPath;
  }

  const tokens = includeField
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0);

  const rewritten = [];
  for (const token of tokens) {
    const normalized = token.toUpperCase();
    if (normalized === "00080060" || normalized === "MODALITY") {
      rewritten.push("00080061");
    } else {
      rewritten.push(token);
    }
  }

  const deduped = [];
  const seen = new Set();
  for (const token of rewritten) {
    const key = token.toUpperCase();
    if (!seen.has(key)) {
      deduped.push(token);
      seen.add(key);
    }
  }

  parsed.searchParams.set("includefield", deduped.join(","));
  return `${parsed.pathname}${parsed.search}`;
}

const server = http.createServer((req, res) => {
  applyCorsHeaders(req, res);

  if (req.method === "OPTIONS") {
    res.statusCode = 204;
    res.end();
    return;
  }

  const rewrittenPath = rewriteStudiesIncludeField(req.url || "", req.method || "");

  const upstream = http.request(
    {
      protocol: "http:",
      hostname: TARGET_HOST,
      port: TARGET_PORT,
      path: rewrittenPath,
      method: req.method,
      headers: maybeRewriteAcceptHeader(
        sanitizeUpstreamHeaders(req.headers),
        req.url || "",
        req.method || ""
      ),
    },
    (upstreamRes) => {
      for (const [key, value] of Object.entries(upstreamRes.headers)) {
        if (value !== undefined) {
          res.setHeader(key, value);
        }
      }

      applyCorsHeaders(req, res);
      res.statusCode = upstreamRes.statusCode || 502;
      upstreamRes.pipe(res);
    }
  );

  upstream.on("error", (error) => {
    applyCorsHeaders(req, res);
    res.statusCode = 502;
    res.setHeader("Content-Type", "application/json");
    res.end(
      JSON.stringify({
        error: "proxy_upstream_error",
        message: error.message,
      })
    );
  });

  req.pipe(upstream);
});

server.listen(PROXY_PORT, () => {
  console.log(
    `CORS reverse proxy running on http://127.0.0.1:${PROXY_PORT} -> http://${TARGET_HOST}:${TARGET_PORT}`
  );
  console.log(`Allowed origin: ${ALLOWED_ORIGIN}`);
});
