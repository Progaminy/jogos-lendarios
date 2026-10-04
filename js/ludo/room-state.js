(() => {
  'use strict';

  function create(getToken) {
    if (typeof getToken !== 'function') throw new Error('Token do Ludo indisponível.');

    function cleanItems(items) {
      return (Array.isArray(items) ? items : []).filter(item => item && typeof item === 'object');
    }

    function maxItemId(items) {
      let max = 0;
      for (const item of cleanItems(items)) max = Math.max(max, Number(item?.id) || 0);
      return max;
    }

    function mergeItems(previous, incoming, limit = 50) {
      const map = new Map();
      for (const item of [...cleanItems(previous), ...cleanItems(incoming)]) {
        map.set(String(item?.id ?? ''), item);
      }
      return [...map.values()]
        .sort((a, b) => (Number(a?.id) || 0) - (Number(b?.id) || 0))
        .slice(-limit);
    }

    async function attachExtras(base, previous = null) {
      if (!base?.room?.id) return base;

      const same = Boolean(previous?.room?.id && previous.room.id === base.room.id);
      const afterEvent = same ? maxItemId(previous.events) : 0;
      const afterChat = same ? maxItemId(previous.chat) : 0;
      const includePayouts = base.room.status === 'finished';

      let delta = null;
      try {
        delta = await window.JLApi.rpc('jl_ludo_room_delta', {
          p_token: getToken(),
          p_room: base.room.id,
          p_after_event: afterEvent,
          p_after_chat: afterChat,
          p_include_payouts: includePayouts
        });
      } catch (error) {
        console.warn('ludo delta', error?.message || error);
      }

      const incomingEvents = cleanItems(delta?.events);
      const incomingChat = cleanItems(delta?.chat);
      const previousEvents = cleanItems(previous?.events);
      const previousChat = cleanItems(previous?.chat);
      const events = same ? mergeItems(previousEvents, incomingEvents) : incomingEvents.slice(-50);
      const chat = same ? mergeItems(previousChat, incomingChat) : incomingChat.slice(-50);
      const payouts = includePayouts
        ? (delta?.payouts || previous?.payouts || [])
        : (same ? (previous?.payouts || []) : []);

      return { ...base, events, chat, payouts };
    }

    async function load(roomId, previous = null) {
      const light = await window.JLApi.rpc('jl_ludo_room_state_light', {
        p_token: getToken(),
        p_room: roomId
      });
      return attachExtras(light, previous);
    }

    return Object.freeze({
      attachExtras,
      load
    });
  }

  window.JLLudoRoomState = Object.freeze({ create });
})();