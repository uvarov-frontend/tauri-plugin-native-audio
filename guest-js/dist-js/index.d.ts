export type NativeAudioStatus = 'idle' | 'loading' | 'playing' | 'ended' | 'error';

export type NativeAudioState = {
  status: NativeAudioStatus;
  currentTime: number;
  duration: number;
  isPlaying: boolean;
  buffering: boolean;
  rate: number;
  error?: string;
};

export type NativeAudioSetSourcePayload = {
  src: string;
  title?: string;
  artist?: string;
  artworkUrl?: string;
};

export declare const initialize: () => Promise<NativeAudioState>;
export declare const setSource: (payload: NativeAudioSetSourcePayload) => Promise<NativeAudioState>;
export declare const play: () => Promise<NativeAudioState>;
export declare const pause: () => Promise<NativeAudioState>;
export declare const seekTo: (position: number) => Promise<NativeAudioState>;
export declare const setRate: (rate: number) => Promise<NativeAudioState>;
export declare const getState: () => Promise<NativeAudioState>;
export declare const dispose: () => Promise<void>;
export declare const addStateListener: (handler: (state: NativeAudioState) => void) => Promise<() => void>;
