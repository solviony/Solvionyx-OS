
project('solvionyx-app-store', 'vala',
  version: '1.0.0',
  meson_version: '>=0.59.0'
)

gnome = import('gnome')

sources = [
  'src/main.vala',
  'src/window.vala'
]

deps = [
  dependency('gtk4'),
  dependency('libadwaita-1'),
  dependency('json-glib-1.0')
]

executable('solvionyx-app-store', sources,
  dependencies: deps,
  install: true
)

install_data('data/com.solvionyx.AppStore.desktop',
  install_dir: join_paths(get_option('datadir'), 'applications')
)

install_data('data/icons/hicolor/scalable/apps/solvionyx-app-store.svg',
  install_dir: join_paths(get_option('datadir'), 'icons/hicolor/scalable/apps')
)
