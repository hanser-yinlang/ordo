/**
 * Ordo · 深链解析(ordo:// scheme)
 * 契约来源:docs/04-UI设计规范.md §7(各端实现映射:鸿蒙端声明 ordo:// scheme)
 *
 * 支持形式:
 *   ordo://inbox | today | upcoming | anytime | someday | logbook
 *   ordo://project/<id>
 *   ordo://todo/<id>
 *   ordo://tag/<名称,需 URL 编码>
 *   ordo://add?title=<标题,需 URL 编码>
 *
 * 纯 ArkTS:不使用 any,不使用动态属性访问。
 */

export type DeepLinkKind = 'list' | 'project' | 'todo' | 'tag' | 'add' | 'unknown';

export interface DeepLinkTarget {
  kind: DeepLinkKind;
  /** list = 清单名;project/todo = id;tag = 标签名;add = 标题 */
  value: string;
  title: string;
}

const LIST_NAMES: string[] = ['inbox', 'today', 'upcoming', 'anytime', 'someday', 'logbook'];

/** 清单名是否属于契约 §4 的内置清单 */
export function listKindOf(value: string): string | null {
  if (LIST_NAMES.indexOf(value) >= 0) {
    return value;
  }
  return null;
}

/** 解析一个 URL 的 query 参数(不依赖 URL 类,避免各端差异) */
function queryParam(uri: string, key: string): string {
  const at: number = uri.indexOf('?');
  if (at < 0) {
    return '';
  }
  const query: string = uri.substring(at + 1);
  const pairs: string[] = query.split('&');
  for (let i = 0; i < pairs.length; i++) {
    const pair: string = pairs[i];
    const eq: number = pair.indexOf('=');
    if (eq < 0) {
      continue;
    }
    const k: string = pair.substring(0, eq);
    if (k === key) {
      return decodeURIComponent(pair.substring(eq + 1));
    }
  }
  return '';
}

/** 去掉 scheme 与 query,得到路径部分 */
function pathOf(uri: string): string {
  let rest: string = uri;
  const schemeAt: number = rest.indexOf('://');
  if (schemeAt >= 0) {
    rest = rest.substring(schemeAt + 3);
  }
  const questionAt: number = rest.indexOf('?');
  if (questionAt >= 0) {
    rest = rest.substring(0, questionAt);
  }
  const hashAt: number = rest.indexOf('#');
  if (hashAt >= 0) {
    rest = rest.substring(0, hashAt);
  }
  while (rest.length > 0 && rest.charAt(rest.length - 1) === '/') {
    rest = rest.substring(0, rest.length - 1);
  }
  return rest;
}

/**
 * 解析深链。
 * 说明:host 部分既可能是清单名(ordo://today),也可能是类别(ordo://project/<id>)。
 */
export function parseDeepLink(uri: string): DeepLinkTarget {
  const unknown: DeepLinkTarget = { kind: 'unknown', value: '', title: '' };
  if (uri === null || uri === undefined || uri.length === 0) {
    return unknown;
  }
  const path: string = pathOf(uri);
  if (path.length === 0) {
    return unknown;
  }
  const segments: string[] = path.split('/');
  const head: string = segments.length > 0 ? segments[0] : '';
  const second: string = segments.length > 1 ? segments[1] : '';

  // ordo://add?title=xxx
  if (head === 'add') {
    const title: string = queryParam(uri, 'title');
    const target: DeepLinkTarget = { kind: 'add', value: '', title: title };
    return target;
  }

  // ordo://project/<id> / ordo://todo/<id> / ordo://tag/<name>
  if (head === 'project' || head === 'todo' || head === 'tag') {
    if (second.length === 0) {
      return unknown;
    }
    const decoded: string = decodeURIComponent(second);
    if (head === 'project') {
      const t: DeepLinkTarget = { kind: 'project', value: decoded, title: '' };
      return t;
    }
    if (head === 'todo') {
      const t: DeepLinkTarget = { kind: 'todo', value: decoded, title: '' };
      return t;
    }
    const t: DeepLinkTarget = { kind: 'tag', value: decoded, title: '' };
    return t;
  }

  // ordo://today 等内置清单
  const listName: string | null = listKindOf(head);
  if (listName !== null) {
    const t: DeepLinkTarget = { kind: 'list', value: listName, title: '' };
    return t;
  }

  // 兼容 ordo://list/today 形式
  if (head === 'list' && second.length > 0) {
    const inner: string | null = listKindOf(second);
    if (inner !== null) {
      const t: DeepLinkTarget = { kind: 'list', value: inner, title: '' };
      return t;
    }
  }

  return unknown;
}

/** 生成分享用的深链(供 UI 的"复制链接"使用) */
export function buildTodoLink(todoId: string): string {
  return 'ordo://todo/' + encodeURIComponent(todoId);
}

export function buildProjectLink(projectId: string): string {
  return 'ordo://project/' + encodeURIComponent(projectId);
}

export function buildTagLink(tagName: string): string {
  return 'ordo://tag/' + encodeURIComponent(tagName);
}

export function buildAddLink(title: string): string {
  return 'ordo://add?title=' + encodeURIComponent(title);
}
