/**
 * Ordo · ohosTest 测试入口(聚合四组用例)
 * 运行:DevEco Studio → 右键 entry/src/ohosTest → Run 'OhosTest'
 */

import naturalDateParserTest from './NaturalDateParser.test';
import listQueryTest from './ListQuery.test';
import repeatEngineTest from './RepeatEngine.test';
import syncMergeTest from './SyncMerge.test';

export default function testsuite() {
  naturalDateParserTest();
  listQueryTest();
  repeatEngineTest();
  syncMergeTest();
}
