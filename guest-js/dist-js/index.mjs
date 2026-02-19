import { addPluginListener, invoke } from '@tauri-apps/api/core';

const PLUGIN_NAME = 'native-audio';
const STATE_EVENT = 'native_audio_state';

const call = async (command, payload) => {
  return await invoke(`plugin:${PLUGIN_NAME}|${command}`, payload);
};

export const initialize = async () => await call('initialize');
export const setSource = async (payload) => await call('set_source', payload);
export const play = async () => await call('play');
export const pause = async () => await call('pause');
export const seekTo = async (position) => await call('seek_to', { position });
export const setRate = async (rate) => await call('set_rate', { rate });
export const getState = async () => await call('get_state');
export const dispose = async () => await call('dispose');
export const addStateListener = async (handler) => await addPluginListener(PLUGIN_NAME, STATE_EVENT, handler);
