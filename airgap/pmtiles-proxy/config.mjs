import fs from 'node:fs';

const themes = new Set(['base', 'buildings', 'places', 'divisions', 'transportation', 'addresses']);
const identifier = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

export function loadConfig(env = process.env) {
  const required = (name) => {
    if (!env[name]) throw new Error(`Missing ${name}`);
    return env[name];
  };
  const publicationId = required('PROXY_PUBLICATION_ID');
  if (!identifier.test(publicationId)) throw new Error('Invalid PROXY_PUBLICATION_ID');
  const bucket = required('PROXY_S3_BUCKET');
  if (!/^[a-z0-9][a-z0-9.-]*[a-z0-9]$/.test(bucket)) throw new Error('Invalid PROXY_S3_BUCKET');
  const prefix = required('PROXY_S3_PREFIX').replace(/\/$/, '');
  if (!prefix.split('/').every((part) => identifier.test(part))) throw new Error('Invalid PROXY_S3_PREFIX');
  const endpoint = new URL(required('S3_ENDPOINT_URL'));
  if (!['http:', 'https:'].includes(endpoint.protocol) || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    throw new Error('Invalid S3_ENDPOINT_URL');
  }
  if (env.NODE_EXTRA_CA_CERTS) fs.accessSync(env.NODE_EXTRA_CA_CERTS, fs.constants.R_OK);
  const region = required('S3_REGION');
  const pathStyle = env.PROXY_S3_FORCE_PATH_STYLE ?? 'true';
  if (!['true', 'false'].includes(pathStyle)) throw new Error('Invalid PROXY_S3_FORCE_PATH_STYLE');
  const credentials = JSON.parse(fs.readFileSync(required('PROXY_CREDENTIALS_FILE'), 'utf8'));
  for (const key of ['accessKeyId', 'secretAccessKey']) {
    if (typeof credentials[key] !== 'string' || !credentials[key].trim()) throw new Error('Invalid proxy credentials file');
  }
  if (credentials.sessionToken !== undefined && (typeof credentials.sessionToken !== 'string' || !credentials.sessionToken)) {
    throw new Error('Invalid proxy session token');
  }
  const manifest = JSON.parse(fs.readFileSync(required('PROXY_MANIFEST_FILE'), 'utf8'));
  if (manifest.schema_version !== 1 || typeof manifest.release !== 'string' || !manifest.release ||
      !Array.isArray(manifest.themes) || !manifest.themes.length ||
      new Set(manifest.themes).size !== manifest.themes.length ||
      !Array.isArray(manifest.objects) || manifest.objects.length !== manifest.themes.length) {
    throw new Error('Invalid publication manifest');
  }
  const objects = new Map();
  for (const [index, theme] of manifest.themes.entries()) {
    const object = manifest.objects[index];
    const key = `${prefix}/${theme}.pmtiles`;
    if (!themes.has(theme) || object?.theme !== theme || object.filename !== `${theme}.pmtiles` ||
        object.uri !== `s3://${bucket}/${key}` || !Number.isSafeInteger(object.size) || object.size < 8) {
      throw new Error('Publication object is invalid or outside the permitted S3 prefix');
    }
    objects.set(`/pmtiles/${publicationId}/${theme}.pmtiles`, { key, size: object.size });
  }
  const origins = new Set((env.PROXY_CORS_ORIGINS ?? '').split(',').map((v) => v.trim()).filter(Boolean));
  for (const origin of origins) {
    const url = new URL(origin);
    if (!['http:', 'https:'].includes(url.protocol) || url.origin !== origin) throw new Error('Invalid PROXY_CORS_ORIGINS');
  }
  const port = Number(env.PORT ?? 8080);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid PORT');
  return { publicationId, bucket, objects, origins, port, endpoint: endpoint.href, region,
    forcePathStyle: pathStyle === 'true',
    credentials: { accessKeyId: credentials.accessKeyId, secretAccessKey: credentials.secretAccessKey,
      ...(credentials.sessionToken ? { sessionToken: credentials.sessionToken } : {}) } };
}
