import http from '@ohos.net.http';
import { clashApiHeaders } from './ClashAuth';

/** 通过内核 clash API(/connections)轮询流量累计值,差分得到实时速率。 */

/** 历史缺省端口:ConfigBuilder/ClashApi 仍在引用,真实端口以设置页 clashApiPort 为准。 */
export const CLASH_API_PORT: number = 19290;

export interface TrafficTotals {
  up: number;
  down: number;
}

/** 复用同一个 HTTP 客户端:此前每次轮询都 create/destroy,1Hz 下对象抖动明显。
 *  进程内只保留一份,请求失败也不重建(连接器会自动恢复)。 */
let trafficClient: http.HttpRequest | null = null;

function sharedTrafficClient(): http.HttpRequest {
  if (trafficClient === null) {
    trafficClient = http.createHttp();
  }
  return trafficClient;
}

export async function fetchTrafficTotals(port: number, secret: string): Promise<TrafficTotals | null> {
  const client = sharedTrafficClient();
  try {
    const resp = await client.request(`http://127.0.0.1:${port}/connections`, {
      method: http.RequestMethod.GET,
      header: clashApiHeaders(secret),
      connectTimeout: 1500,
      readTimeout: 1500,
      expectDataType: http.HttpDataType.STRING
    });
    if (resp.responseCode !== 200) {
      return null;
    }
    const obj = JSON.parse(`${resp.result}`) as Record<string, Object>;
    const up = Number(obj['uploadTotal']);
    const down = Number(obj['downloadTotal']);
    if (isNaN(up) || isNaN(down)) {
      return null;
    }
    const t: TrafficTotals = { up: up, down: down };
    return t;
  } catch (e) {
    return null;
  }
}

export function formatBytes(n: number): string {
  if (n < 1024) {
    return `${n} B`;
  }
  const kb = n / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(1)} KB`;
  }
  const mb = kb / 1024;
  if (mb < 1024) {
    return `${mb.toFixed(1)} MB`;
  }
  return `${(mb / 1024).toFixed(2)} GB`;
}

export function formatSpeed(bytesPerSec: number): string {
  if (bytesPerSec < 1024) {
    return `${bytesPerSec} B/s`;
  }
  const kb = bytesPerSec / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(1)} KB/s`;
  }
  return `${(kb / 1024).toFixed(1)} MB/s`;
}
