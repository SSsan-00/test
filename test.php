<?php

// データベース接続に必要な設定や関数を定義しているファイルを読み込みます
require_once "./includes/config.php";

try {
    // connectDatabase() は、config.php 内で定義されているデータベース接続関数です。
    // この関数を実行して PDO オブジェクトを取得します。
    $pdo = connectDatabase();

    // 現在の日時を取得するための SQL クエリを実行します
    $stmt = $pdo->query("SELECT NOW()");

    // クエリ結果の最初のカラム（現在の日時）を取得します
    $result = $stmt->fetchColumn();

    // データベース接続に成功した場合、成功メッセージと現在の日時を表示します
    echo "データベース接続成功！現在の日時: " . $result;
} catch (Exception $e) {
    // 例外が発生した場合は、エラーメッセージを表示します
    echo "データベース接続失敗: " . $e->getMessage();

    // ★ デバッグ用追加情報 ★
    // 例外が発生した場合のスタックトレース（エラー発生箇所の詳細な情報）を表示します。
    // これにより、どこで問題が発生しているかを詳細に把握できます。
    echo "<pre>" . $e->getTraceAsString() . "</pre>";
}
?>
