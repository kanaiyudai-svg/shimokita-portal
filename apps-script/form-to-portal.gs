/**
 * 議案提出フォームの回答を、ポータルの「非公開の議案」として登録する（フォームにひも付けて使う）。
 *
 * 設定（独立したスクリプトとして作る。フォームの所有アカウントで行う）:
 *   1. script.google.com で新しいプロジェクトを作り、このコードを貼る
 *   2. プロジェクトの設定 > スクリプト プロパティ に FORM_SECRET を追加し、合言葉を入れる
 *      （合言葉のハッシュは Supabase の app_secrets に登録済み。合言葉本体はここにだけ置く）
 *   3. 関数 setupTrigger を1回実行し、権限を許可する（フォーム送信時のトリガーが作られる）
 *
 * 失敗したときは、スクリプトの所有者にメールが届く。回答自体はフォームの「回答」に必ず残る。
 * 引継ぎ: フォームとこのスクリプトは同じアカウントが持つ。管理者を替えるときは両方の所有者を移す。
 */
const FORM_ID = '1U1TOMOjSAiqV-h2QqFDahPH1ToatmOG6kmgojSYIl_8';
const SUPABASE_URL = 'https://ggdjoxnjwqthhkwpcvqq.supabase.co';
// 公開用のキー（ポータルのHTMLにも入っている）。守りはSupabase側の権限と合言葉が担う
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdnZGpveG5qd3F0aGhrd3BjdnFxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgxNTYyNjIsImV4cCI6MjA5MzczMjI2Mn0.X1AvGI5I8I94siB6MS1B_ou9TlA5864wUNsuy6SK4bc';

// フォームの質問文の先頭でひも付ける（文言を少し直しても動くように前方一致）
const FIELD_PREFIX = {
  name:    '氏名',
  email:   'email',
  title:   '議案',
  summary: '概要',
  reason:  '理由',
  note:    'その他',
};

/** 1回だけ実行する。フォーム送信時に onFormSubmit が動くようにする（重複して作らない） */
function setupTrigger() {
  ScriptApp.getProjectTriggers().forEach(t => { if (t.getHandlerFunction() === 'onFormSubmit') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('onFormSubmit').forForm(FormApp.openById(FORM_ID)).onFormSubmit().create();
}

function onFormSubmit(e) {
  const answers = {};
  e.response.getItemResponses().forEach(r => {
    const q = r.getItem().getTitle();
    Object.keys(FIELD_PREFIX).forEach(k => {
      if (answers[k] === undefined && q.indexOf(FIELD_PREFIX[k]) === 0) answers[k] = String(r.getResponse() || '');
    });
  });

  const body = {
    p_secret:  PropertiesService.getScriptProperties().getProperty('FORM_SECRET'),
    p_name:    answers.name || '',
    p_email:   answers.email || '',
    p_title:   answers.title || '',
    p_summary: answers.summary || '',
    p_reason:  answers.reason || '',
    p_note:    answers.note || '',
  };

  let res;
  try {
    res = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/submit_proposal', {
      method: 'post',
      contentType: 'application/json',
      headers: { apikey: SUPABASE_ANON, Authorization: 'Bearer ' + SUPABASE_ANON },
      payload: JSON.stringify(body),
      muteHttpExceptions: true,
    });
  } catch (err) {
    notifyOwner_('通信に失敗しました: ' + err, answers);
    return;
  }
  const code = res.getResponseCode();
  // 200=登録成功。409=同じ人の同じ議案の重複（10分以内）なので何もしない
  if (code !== 200 && code !== 409) notifyOwner_('登録に失敗しました（HTTP ' + code + '）: ' + res.getContentText(), answers);
}

function notifyOwner_(reason, answers) {
  MailApp.sendEmail({
    to: Session.getEffectiveUser().getEmail(),
    subject: '【みんカレポータル】議案フォームの自動登録に失敗しました',
    body: reason + '\n\n議案: ' + (answers.title || '(不明)') + '\n提出者: ' + (answers.name || '(不明)') +
          '\n\n回答はフォームの「回答」に残っています。管理画面の「新しい議案」から手で登録してください。',
  });
}
