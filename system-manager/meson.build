
project('solvionyx-system-manager', 'vala',
  version: '1.0.0',
  meson_version: '>=0.59.0'
)

gnome = import('gnome')

sources = [
  'src/main.vala',
  'src/window.vala',
  'src/pages/system_info.vala',
  'src/pages/themes.vala',
  'src/pages/layouts.vala',
  'src/pages/updates.vala',
  'src/pages/drivers.vala',
  'src/pages/network.vala',
  'src/pages/about.vala'
]

deps = [
  dependency('gtk4'),
  dependency('libadwaita-1')
]

executable('solvionyx-system-manager', sources,
  dependencies: deps,
  install: true
)

install_subdir('data/ui',
  install_dir: join_paths(get_option('datadir'), 'solvionyx-system-manager/ui')
)

install_data('data/org.solvionyx.SystemManager.desktop',
  install_dir: join_paths(get_option('datadir'), 'applications')
)

install_data('data/icons/hicolor/scalable/apps/solvionyx-system-manager.svg',
  install_dir: join_paths(get_option('datadir'), 'icons/hicolor/scalable/apps')
)
