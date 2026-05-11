export type HttpAutoLogRequest = {
  url?: string | undefined;
};

const CS2_GAMESTATE_PATH = '/api/cs2/gamestate';

export function shouldIgnoreHttpAutoLog(req: HttpAutoLogRequest): boolean {
  return pathFromUrl(req.url) === CS2_GAMESTATE_PATH;
}

function pathFromUrl(url: string | undefined): string {
  return url?.split('?', 1)[0] ?? '';
}
