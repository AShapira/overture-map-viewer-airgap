import { S3Client, GetObjectCommand, HeadObjectCommand } from '@aws-sdk/client-s3';
import { NodeHttpHandler } from '@smithy/node-http-handler';
import https from 'node:https';
import http from 'node:http';

export function createStorage(config) {
  const client = new S3Client({
    endpoint: config.endpoint, region: config.region, forcePathStyle: config.forcePathStyle,
    credentials: config.credentials, maxAttempts: 2,
    requestHandler: new NodeHttpHandler({
      connectionTimeout: 5000, socketTimeout: 60000,
      httpAgent: new http.Agent({ keepAlive: true, maxSockets: 64 }),
      httpsAgent: new https.Agent({ keepAlive: true, maxSockets: 64 }),
    }),
  });
  return {
    async request(method, object, headers, signal) {
      const input = { Bucket: config.bucket, Key: object.key };
      if (headers.range) input.Range = headers.range;
      if (headers['if-match']) input.IfMatch = headers['if-match'];
      if (headers['if-none-match']) input.IfNoneMatch = headers['if-none-match'];
      const result = await client.send(method === 'HEAD' ? new HeadObjectCommand(input) : new GetObjectCommand(input), { abortSignal: signal });
      return { status: result.$metadata.httpStatusCode, length: result.ContentLength,
        range: result.ContentRange, etag: result.ETag, modified: result.LastModified?.toUTCString(),
        encoding: result.ContentEncoding, body: result.Body };
    },
    close() { client.destroy(); },
  };
}
