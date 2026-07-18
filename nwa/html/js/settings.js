import {
  loadNwaConfig,
  resolveTheme
} from '/js/weblib.js';

console.log('settings.js loaded');

initializeSettings();

async function initializeSettings() {
  let nwaConfig = {};

  try {
    nwaConfig = await loadNwaConfig();
  } catch (err) {
    console.error('Failed to load NWA config:', err);
  }

  const themeSelect =
    document.getElementById('themeSelect');

  const themeDescription =
    document.getElementById('themeDescription');

  if (!themeSelect || !themeDescription) {
    console.error('Theme settings elements not found');
    return;
  }

  const savedTheme = localStorage.getItem('theme');

  const configuredDefault =
    nwaConfig?.APPEARANCE?.default_theme === 'light'
      ? 'light'
      : 'dark';

  // Show whether the browser is using an override
  // or the application-configured default.
  if (savedTheme === 'light' || savedTheme === 'dark') {
    themeSelect.value = savedTheme;
  } else {
    themeSelect.value = 'default';
  }

  updateThemeDescription(
    themeSelect.value,
    configuredDefault,
    themeDescription
  );

  themeSelect.addEventListener('change', event => {
    const selectedTheme = event.target.value;

    if (selectedTheme === 'default') {
      localStorage.removeItem('theme');

      document.documentElement.setAttribute(
        'data-bs-theme',
        configuredDefault
      );
    } else {
      localStorage.setItem('theme', selectedTheme);

      document.documentElement.setAttribute(
        'data-bs-theme',
        selectedTheme
      );
    }

    updateThemeDescription(
      selectedTheme,
      configuredDefault,
      themeDescription
    );
  });
}

function updateThemeDescription(
  selectedTheme,
  configuredDefault,
  descriptionElement
) {
  if (selectedTheme === 'default') {
    descriptionElement.textContent =
      `Using the application default: ${configuredDefault}.`;
    return;
  }

  descriptionElement.textContent =
    `Using a browser-specific ${selectedTheme} theme override.`;
}