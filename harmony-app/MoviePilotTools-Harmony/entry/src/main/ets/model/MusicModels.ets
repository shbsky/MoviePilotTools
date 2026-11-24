import { formatDuration } from '../common/Format';
import { jStr, jNum, jBool } from '../common/AppConstants';

/**
 * Songloft 音乐服务本地模型，移植安卓 data/MusicModels.kt。
 * 服务端字段是 snake_case（cover_url / file_path / bit_rate），
 * 解析时对两种写法都兼容（见 SongloftClient）。
 */

export class MusicSong {
  id: number = 0;
  title: string = '';
  artist: string = '';
  album: string = '';
  durationSeconds: number = 0;
  /** 已归一化成绝对地址（相对路径会补上服务器前缀） */
  streamUrl: string = '';
  coverUrl: string = '';
  format: string = '';
  bitRate: number = 0;
  isVideo: boolean = false;

  durationText(): string {
    return formatDuration(this.durationSeconds);
  }
}

export class MusicPlaylist {
  id: number = 0;
  name: string = '';
  description: string = '';
  songCount: number = 0;
  coverUrl: string = '';
  type: string = '';
}

export class MusicLibraryStats {
  totalSongs: number = 0;
  artistCount: number = 0;
  albumCount: number = 0;
  totalDuration: number = 0;
}

/** 音乐页整体状态 */
export class MusicUiState {
  configured: boolean = false;
  serverLabel: string = '';
  songs: MusicSong[] = [];
  total: number = 0;
  loading: boolean = false;
  loadingMore: boolean = false;
  error: string = '';
  stats: MusicLibraryStats | null = null;
  playlists: MusicPlaylist[] = [];
  playlistsLoading: boolean = false;
  searchActive: boolean = false;
  query: string = '';
  /** 正在查看的歌单，null = 全部歌曲 */
  playlist: MusicPlaylist | null = null;
  playlistSongs: MusicSong[] = [];
  playlistLoading: boolean = false;
  /** 已收藏歌曲 id 集合（服务端内建「收藏」歌单），红心标记用 */
  favoriteIds: Set<number> = new Set<number>();
  toast: string = '';

  visibleSongs(): MusicSong[] {
    return this.playlist === null ? this.songs : this.playlistSongs;
  }

  /** 不可变快照：每次状态变更生成新对象（数组字段按引用共享，整体替换） */
  copy(): MusicUiState {
    const c: MusicUiState = new MusicUiState();
    c.configured = this.configured;
    c.serverLabel = this.serverLabel;
    c.songs = this.songs;
    c.total = this.total;
    c.loading = this.loading;
    c.loadingMore = this.loadingMore;
    c.error = this.error;
    c.stats = this.stats;
    c.playlists = this.playlists;
    c.playlistsLoading = this.playlistsLoading;
    c.searchActive = this.searchActive;
    c.query = this.query;
    c.playlist = this.playlist;
    c.playlistSongs = this.playlistSongs;
    c.playlistLoading = this.playlistLoading;
    c.favoriteIds = this.favoriteIds;
    c.toast = this.toast;
    return c;
  }
}

/** 播放器状态（迷你条 + 全屏页 + 投送合并都用它） */
export class PlaybackState {
  current: MusicSong | null = null;
  isPlaying: boolean = false;
  positionMs: number = 0;
  durationMs: number = 0;
  hasPrevious: boolean = false;
  hasNext: boolean = false;
  /** 本机播放音量 0..1（和系统媒体音量叠加） */
  volume: number = 1;
  /** 循环模式：0 = 列表结束即停，1 = 单曲循环，2 = 列表循环 */
  repeatMode: number = 0;
  /** 投送目标设备名；null = 本机扬声器 */
  castingTo: string | null = null;
  error: string | null = null;

  progress(): number {
    if (this.durationMs <= 0) {
      return 0;
    }
    const p: number = this.positionMs / this.durationMs;
    if (p < 0) {
      return 0;
    }
    if (p > 1) {
      return 1;
    }
    return p;
  }

  copy(): PlaybackState {
    const c: PlaybackState = new PlaybackState();
    c.current = this.current;
    c.isPlaying = this.isPlaying;
    c.positionMs = this.positionMs;
    c.durationMs = this.durationMs;
    c.hasPrevious = this.hasPrevious;
    c.hasNext = this.hasNext;
    c.volume = this.volume;
    c.repeatMode = this.repeatMode;
    c.castingTo = this.castingTo;
    c.error = this.error;
    return c;
  }
}

export function musicSongFromJson(o: Record<string, Object>): MusicSong {
  const s: MusicSong = new MusicSong();
  s.id = Math.trunc(jNum(o, ['id'], 0));
  s.title = jStr(o, ['title', 'name']);
  s.artist = jStr(o, ['artist', 'artist_name']);
  s.album = jStr(o, ['album', 'album_name']);
  s.durationSeconds = Math.trunc(jNum(o, ['duration', 'duration_seconds', 'durationSeconds'], 0));
  s.streamUrl = jStr(o, ['stream_url', 'streamUrl', 'url', 'file_path', 'filePath']);
  s.coverUrl = jStr(o, ['cover_url', 'coverUrl', 'cover']);
  s.format = jStr(o, ['format']);
  s.bitRate = Math.trunc(jNum(o, ['bit_rate', 'bitRate', 'bitrate'], 0));
  s.isVideo = jBool(o, ['is_video', 'isVideo', 'video']);
  return s;
}

export function musicPlaylistFromJson(o: Record<string, Object>): MusicPlaylist {
  const p: MusicPlaylist = new MusicPlaylist();
  p.id = Math.trunc(jNum(o, ['id'], 0));
  p.name = jStr(o, ['name', 'title']);
  p.description = jStr(o, ['description', 'desc']);
  p.songCount = Math.trunc(jNum(o, ['song_count', 'songCount', 'count'], 0));
  p.coverUrl = jStr(o, ['cover_url', 'coverUrl', 'cover']);
  p.type = jStr(o, ['type']);
  return p;
}
