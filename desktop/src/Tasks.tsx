import { useState } from 'react';
import type { Task } from './bridge';
import { command } from './bridge';
import { labels, type Phase } from './theme';
const priority = (t: Task) =>
  t.phase === 'attention'
    ? 0
    : ['error', 'check_failed'].includes(t.phase) && !t.acknowledged
      ? 1
      : !t.ended
        ? 2
        : 3;
export function Tasks({ tasks, refresh }: { tasks: Task[]; refresh: () => Promise<void> }) {
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [history, setHistory] = useState(false);
  const rows = [...tasks].sort((a, b) => priority(a) - priority(b) || b.updated_ns - a.updated_ns);
  const visible = rows.filter(
    (t) =>
      history ||
      !t.ended ||
      (!t.acknowledged && ['error', 'check_failed', 'verified', 'complete'].includes(t.phase)),
  );
  const act = async (name: string, task: Task) => {
    setBusy(true);
    setError('');
    try {
      await command(name, {
        provider: task.provider,
        sessionId: task.session_id,
        turnId: task.turn_id,
      });
      await refresh();
    } catch {
      setError(
        name === 'open_task' ? '无法打开会话，请在 Codex 中查看' : '状态已变化，请刷新后重试',
      );
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="tasks-panel" aria-label="任务状态">
      <div className="tasks-heading">
        <h2>任务</h2>
        <label>
          <input type="checkbox" checked={history} onChange={(e) => setHistory(e.target.checked)} />
          显示已确认
        </label>
      </div>
      <div className="task-list">
        {visible.length === 0 ? (
          <p className="task-empty">等待任务事件</p>
        ) : (
          visible.map((t) => {
            const name =
              t.check_type === 'test'
                ? '测试'
                : t.check_type === 'build'
                  ? '构建'
                  : t.provider === 'codex.desktop.local'
                    ? 'Codex'
                    : t.provider;
            const state = t.cancelled
              ? '已取消'
              : t.phase === 'attention'
                ? t.pending_inputs > 0
                  ? '等待回答'
                  : t.pending_approvals > 0
                    ? '等待审批'
                    : '待处理'
                : t.phase === 'unknown'
                  ? '来源不可用'
                  : (labels[t.phase as Phase] ?? t.phase);
            return (
              <div
                className={`task-row task-${t.phase}`}
                key={`${t.provider}:${t.session_id}:${t.turn_id}`}
              >
                <i className="task-indicator" />
                <span className="task-name" title={t.session_id}>
                  {t.label ? `${t.label} · ${name}` : name} <small>{t.session_id.slice(-8)}</small>
                </span>
                <span className="task-state">{state}</span>
                {t.provider === 'codex.desktop.local' && (
                  <button disabled={busy} onClick={() => void act('open_task', t)}>
                    打开
                  </button>
                )}
                {t.ended && !t.acknowledged && (
                  <button disabled={busy} onClick={() => void act('acknowledge_task', t)}>
                    已查看
                  </button>
                )}
              </div>
            );
          })
        )}
      </div>
      {error && (
        <span role="alert" className="error">
          {error}
        </span>
      )}
    </div>
  );
}
