'use strict';
(() => {
  const state = {};
  // Compatibility facade. Analytics owns the shared history sheet and power model.
  const analytics = () => requireFeature('analytics');
  function open() { analytics().open('power'); }
  function stop() { analytics().stop(); }
  function pause() { analytics().pause(); }
  function scheduleDetail(delay) { analytics().schedule(delay); }
  function scheduleSystem(delay) { analytics().schedule(delay); }
  function formatDuration(sec) {
    return requireFeature('analyticsModel').formatDuration(sec);
  }
  registerFeature('energy', {
    open,
    stop,
    pause,
    scheduleDetail,
    scheduleSystem,
    formatDuration,
    openEnergyDetail: open
  });
})();
