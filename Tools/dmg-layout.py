"""Persist the install window's Finder icon positions in the disk image."""
import sys
from pathlib import Path
from ds_store import DSStore

WINDOW_BOUNDS = '{{200, 160}, {640, 360}}'
APP_POSITION = (180, 150)
APPLICATIONS_POSITION = (460, 150)


def write_layout(folder):
    with DSStore.open(str(folder / '.DS_Store'), 'w+') as store:
        store['.']['vSrn'] = ('long', 1)
        store['.']['icvl'] = ('type', b'icnv')
        store['.']['bwsp'] = {
            'WindowBounds': WINDOW_BOUNDS,
            'ShowToolbar': False, 'ShowSidebar': False,
            'ContainerShowSidebar': False, 'ShowStatusBar': False,
            'ShowPathbar': False, 'ShowTabView': False,
            'PreviewPaneVisibility': False, 'SidebarWidth': 0,
        }
        store['.']['icvp'] = {
            'viewOptionsVersion': 1,
            'backgroundType': 1,
            'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
            'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'gridSpacing': 100.0,
            'arrangeBy': 'none', 'showIconPreview': True, 'showItemInfo': False,
            'labelOnBottom': True, 'textSize': 14.0, 'iconSize': 88.0,
            'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
        }
        store['字体检索.app']['Iloc'] = APP_POSITION
        store['应用程序']['Iloc'] = APPLICATIONS_POSITION


def verify_layout(folder):
    with DSStore.open(str(folder / '.DS_Store'), 'r') as store:
        assert store['.']['icvl'] == (b'type', b'icnv')
        window = store['.']['bwsp']
        options = store['.']['icvp']
        left = store['字体检索.app']['Iloc']
        right = store['应用程序']['Iloc']
        assert window['WindowBounds'] == WINDOW_BOUNDS
        assert not window['ShowToolbar'] and not window['ShowSidebar']
        assert left == APP_POSITION and right == APPLICATIONS_POSITION
        assert left[0] < right[0] and left[1] == right[1]
        assert (left[0] + right[0]) / 2 == 640 / 2
        assert options['arrangeBy'] == 'none' and options['iconSize'] == 88.0
        assert options['scrollPositionX'] == options['scrollPositionY'] == 0.0
    print('SUCCESS: Finder layout persisted: app left, Applications right, centered in a 640×360 window')


if __name__ == '__main__':
    checking = sys.argv[1] == '--verify'
    folder = Path(sys.argv[2] if checking else sys.argv[1])
    if not checking:
        write_layout(folder)
    verify_layout(folder)
