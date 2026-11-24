import * as migration_20261124_003727_initial from './20261124_003727_initial';
import * as migration_20261124_060357_blob_object_key from './20261124_060357_blob_object_key';

export const migrations = [
  {
    up: migration_20261124_003727_initial.up,
    down: migration_20261124_003727_initial.down,
    name: '20261124_003727_initial',
  },
  {
    up: migration_20261124_060357_blob_object_key.up,
    down: migration_20261124_060357_blob_object_key.down,
    name: '20261124_060357_blob_object_key'
  },
];
