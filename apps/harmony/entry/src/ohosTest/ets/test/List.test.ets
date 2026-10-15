/**
 * Ordo · ohosTest 测试入口(聚合十三组用例)
 * 运行:DevEco Studio → 右键 entry/src/ohosTest → Run 'OhosTest'
 */

import naturalDateParserTest from './NaturalDateParser.test';
import listQueryTest from './ListQuery.test';
import repeatEngineTest from './RepeatEngine.test';
import syncMergeTest from './SyncMerge.test';
import rowModelTest from './RowModel.test';
import reorderMathTest from './ReorderMath.test';
import pressGestureTest from './PressGesture.test';
import localWorkspaceTest from './LocalWorkspace.test';
import localDataResetTest from './LocalDataReset.test';
import relationalStoreTest from './RelationalStore.test';
import fabMenuTest from './FabMenu.test';
import sheetMetricsTest from './SheetMetrics.test';
import motionScaleTest from './MotionScale.test';

export default function testsuite() {
  naturalDateParserTest();
  listQueryTest();
  repeatEngineTest();
  syncMergeTest();
  rowModelTest();
  reorderMathTest();
  pressGestureTest();

  localWorkspaceTest();
  localDataResetTest();
  relationalStoreTest();
  fabMenuTest();
  sheetMetricsTest();
  motionScaleTest();
}
