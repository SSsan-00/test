<?php
namespace App;

// -------------------------------------------------------------
// FileAnalyzer クラス
// PHP/JS/HTML ソースを走査し、依存関係・CRUD 操作・SQL クエリなどを抽出する
// -------------------------------------------------------------

use PhpOffice\PhpSpreadsheet\Spreadsheet;
use PhpOffice\PhpSpreadsheet\Writer\Xlsx;
use PhpParser\ParserFactory;
use PhpParser\NodeTraverser;
use PhpParser\NodeVisitor\NameResolver;
use PHPSQLParser\PHPSQLParser;
use PhpParser\Node;
use PhpParser\NodeVisitorAbstract;
use DOMDocument;
use DOMXPath;
use Exception;

class FileAnalyzer
{
    /** @var string 解析のルートディレクトリ */
    public string $rootDir;

    /** @var array 解析対象の拡張子リスト */
    public array $targetExtensions = ['php', 'inc', 'js', 'html'];

    /** @var array 抽出された CRUD 操作（全体） */
    public array $crudOperations = [];

    /** @var array ファイルごとの CRUD 操作 */
    public array $fileCrudOperations = [];

    /** @var array エラーログ情報 */
    public array $errorLogs = [];

    /** @var array 変数解決用マップ */
    public array $variableMap = [];

    /** @var array 定数解決用マップ */
    public array $constantMap = [];

    /** @var array 実行時注入用の値 */
    public array $runtimeValues = [];

    /** @var array ビュー一覧（view_list.txt から読み込み） */
    public array $views = [];

    /** @var array ストアドプロシージャ一覧（procedure_list.txt から読み込み） */
    public array $storedProcedures = [];

    /** @var array 抽出した SQL クエリ文字列一覧 */
    public array $sqlQueries = [];

    /** @var array 条件付きクエリパターン */
    public array $conditionalPatterns = [];

    /** @var array 解析中に検出したエンドポイント(URL) */
    public array $endpoints = [];

    /** @var array 依存関係に含めるインクルード済みファイル */
    public array $includedFiles = [];

    /** @var string|null 現在解析中のファイルパス */
    public ?string $currentFile = null;

    /** @var string|null 現在のクラス名 */
    public ?string $currentClass = null;

    /**
     * コンストラクタ
     *
     * @param string $rootDir 解析対象ディレクトリ
     * @throws \RuntimeException 存在しないディレクトリ指定時
     */
    public function __construct(string $rootDir)
    {
        // ディレクトリ存在チェック
        if (!is_dir($rootDir)) {
            throw new \RuntimeException("Directory not found: {$rootDir}");
        }
        $this->rootDir = $rootDir;

        // スーパーグローバル等の初期マッピングを設定
        $this->initializeRuntimeMaps();

        // ビュー・プロシージャ一覧を外部ファイルから読み込み
        $this->loadViewsAndProcedures();
    }

    // =================================================================
    // エラーログ取得／記録
    // =================================================================

    /**
     * これまでに記録されたエラーを返す
     *
     * @return array
     */
    public function getErrorLogs(): array
    {
        return $this->errorLogs;
    }

    /**
     * エラーをログに記録し、ログファイルにも追記する
     *
     * @param string $type    エラー種別 (例: 'analyze_file')
     * @param string $file    発生ファイルパス
     * @param int    $line    発生行番号
     * @param string $message エラーメッセージ
     */
    public function logError(string $type, string $file, int $line, string $message): void
    {
        $entry = [
            'type'      => $type,
            'file'      => $file,
            'line'      => $line,
            'message'   => $message,
            'timestamp' => date('Y-m-d H:i:s'),
        ];
        $this->errorLogs[] = $entry;

        // ディレクトリがなければ作成
        $logFile = dirname(__DIR__) . '/logs/error.log';
        $logDir  = dirname($logFile);
        if (!is_dir($logDir)) {
            mkdir($logDir, 0777, true);
        }

        // ファイルに追記
        $lineStr = sprintf("[%s] %s in %s:%d - %s\n",
            $entry['timestamp'],
            $entry['type'],
            $entry['file'],
            $entry['line'],
            $entry['message']
        );
        file_put_contents($logFile, $lineStr, FILE_APPEND);
    }

    // =================================================================
    // スーパーグローバル／定数マッピング初期化
    // =================================================================

    /**
     * スーパーグローバルやアプリ定数の初期値を設定
     */
    private function initializeRuntimeMaps(): void
    {
        // スーパーグローバル ($_GET, $_POST など) を動的 array 型として登録
        $this->variableMap = [
            '_GET'     => ['type'=>'array','source'=>'dynamic'],
            '_POST'    => ['type'=>'array','source'=>'dynamic'],
            '_REQUEST' => ['type'=>'array','source'=>'dynamic'],
            '_SESSION' => ['type'=>'array','source'=>'dynamic'],
            '_COOKIE'  => ['type'=>'array','source'=>'dynamic'],
            '_SERVER'  => ['type'=>'array','source'=>'system'],
            '_ENV'     => ['type'=>'array','source'=>'system'],
        ];
        // 言語組み込み定数などを登録
        $this->constantMap = [
            'true'       => true,
            'false'      => false,
            'null'       => null,
            'PHP_VERSION'=> PHP_VERSION,
            'APP_NAME'   => 'MyApplication',
        ];
    }

    /**
     * 外部からランタイム注入値を一括登録
     *
     * @param array $values ['VAR_NAME'=>value, ...]
     */
    public function injectRuntimeValues(array $values): void
    {
        foreach ($values as $key => $val) {
            $this->runtimeValues[$key] = $val;
            if (is_string($val)) {
                // 文字列は定数マップにも登録
                $this->constantMap[$key] = $val;
            }
        }
    }

    // =================================================================
    // ビュー／ストアドプロシージャ一覧読み込み
    // =================================================================

    /**
     * view_list.txt, procedure_list.txt からそれぞれの一覧を読み込む
     */
    private function loadViewsAndProcedures(): void
    {
        // ビュー一覧
        $vfile = dirname(__DIR__) . '/view_list.txt';
        if (file_exists($vfile)) {
            foreach (file($vfile, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line) {
                if (strpos(trim($line), '#')===0) continue;
                $name = trim($line);
                $this->views[$name] = ['name'=>$name,'type'=>'view'];
            }
        }
        // プロシージャ一覧
        $pfile = dirname(__DIR__) . '/procedure_list.txt';
        if (file_exists($pfile)) {
            foreach (file($pfile, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line) {
                if (strpos(trim($line), '#')===0) continue;
                $name = trim($line);
                $this->storedProcedures[$name] = ['name'=>$name,'type'=>'stored_procedure'];
            }
        }
    }

    // =================================================================
    // 対象ファイル検出
    // =================================================================

    /**
     * テスト用サンプルを含む、解析対象ファイルのパス一覧を返す
     * 実運用では再帰的に拡張子マッチで収集します
     *
     * @param string $directory ルートディレクトリ
     * @return array ファイルパスの配列
     */
    public function findTargetFiles(string $directory): array
    {
        $files = [];

        // テスト用ファイル作成ロジック（サンプル）
        $testFiles = [
            $directory . '/test.php'  => '<?php echo "test"; ?>',
            $directory . '/test.js'   => 'console.log("test");',
            $directory . '/test.html'=> '<!DOCTYPE html><html><body>test</body></html>',
        ];
        foreach ($testFiles as $path=>$content) {
            if (!file_exists($path)) {
                file_put_contents($path, $content);
            }
            $files[] = $path;
        }

        // 重複除去して返却
        return array_unique($files);
    }

    // =================================================================
    // 全ファイル一括解析エントリ
    // =================================================================

    /**
     * findTargetFiles() で得た各ファイルを analyzeFile() で解析し、
     * 簡易結果（file, dependencies, queries）をまとめて返す
     *
     * @return array
     */
    public function analyzeAllFiles(): array
    {
        $out = [];
        $files = $this->findTargetFiles($this->rootDir);
        foreach ($files as $file) {
            $res = $this->analyzeFile($file);
            if (!empty($res['success'])) {
                $out[] = [
                    'file'         => $res['file'],
                    'file_path'    => $res['file_path'],
                    'dependencies' => $res['dependencies'] ?? [],
                    'queries'      => $res['analysis']['queries'] ?? [],
                ];
            }
        }
        return $out;
    }

    // =================================================================
    // ファイル解析
    // =================================================================

    /**
     * 単一ファイルを解析し、依存関係・CRUD・変数・クエリなどを返す
     *
     * @param string $filePath
     * @return array
     */
    public function analyzeFile(string $filePath): array
    {
        $result = [
            'file'      => $filePath,
            'file_path' => $filePath,
            'analysis'  => [],
        ];
        if (!file_exists($filePath)) {
            $result['success'] = false;
            $result['error']   = 'File not found';
            return $result;
        }
        $this->currentFile = $filePath;
        $content = file_get_contents($filePath);
        if ($content === false) {
            $result['success'] = false;
            $result['error']   = 'Failed to read file';
            return $result;
        }

        $ext = strtolower(pathinfo($filePath, PATHINFO_EXTENSION));
        // 依存関係解析
        $result['dependencies'] = $this->analyzeDependencies($filePath, $content);

        try {
            switch ($ext) {
                case 'php':
                    // PHP 本文解析
                    $php = $this->analyzePhpContent($content);
                    $result['analysis']['php']            = $php;
                    $result['analysis']['queries']        = $php['queries'] ?? [];
                    $result['analysis']['sql_queries']    = $php['sql_queries'] ?? [];
                    $result['analysis']['crud_operations']= $this->analyzeCrudOperations($content, $filePath);
                    $result['analysis']['external_access']= $this->analyzeExternalAccess($content);
                    $result['analysis']['conditional_patterns'] = $this->analyzeConditionalQueries($content, $filePath);
                    break;
                case 'js':
                    $js  = $this->analyzeJsContent($content);
                    $result['analysis']['js']             = $js;
                    $result['analysis']['external_access']= $this->analyzeExternalAccess($content);
                    break;
                case 'html':
                case 'htm':
                    $html= $this->analyzeHtmlContent($content);
                    $result['analysis']['html']           = $html;
                    $result['analysis']['external_access']= $this->analyzeExternalAccess($content);
                    break;
                default:
                    // その他はフォールバック
                    $result['analysis']['fallback'] = $this->fallbackParse($content);
                    $this->logError('analyze_file', $filePath, 0, "Unsupported extension: {$ext}");
            }
            $result['success'] = true;
        } catch (Exception $e) {
            $this->logError('analyze_file', $filePath, 0, $e->getMessage());
            $result['success'] = false;
            $result['error']   = $e->getMessage();
        }

        return $result;
    }

    // =================================================================
    // 依存関係解析 (include/require)
    // =================================================================

    /**
     * require/include を正規表現で検出し、ファイルパスを解決・再帰解析
     *
     * @param string $filePath
     * @param string $content
     * @return array 依存ファイルパスリスト
     */
    private function analyzeDependencies(string $filePath, string $content): array
    {
        $deps = [];
        $base = dirname($filePath);
        $patterns = [
            '/require(?:_once)?\s*[\'"]([^\'"]+)[\'"]/',
            '/include(?:_once)?\s*[\'"]([^\'"]+)[\'"]/',
        ];
        foreach ($patterns as $pat) {
            if (preg_match_all($pat, $content, $m)) {
                foreach ($m[1] as $rel) {
                    $resolved = $this->resolveIncludePath($rel, $base);
                    if (file_exists($resolved)) {
                        $deps[] = $resolved;
                        // 再帰的に依存関係を集約
                        $sub = $this->analyzeDependencies($resolved, file_get_contents($resolved));
                        $deps = array_merge($deps, $sub);
                    }
                }
            }
        }
        // 重複除去して返却
        return array_unique($deps);
    }

    /**
     * include/require のファイル名から実際のパスを解決
     *
     * @param string $file
     * @param string $baseDir
     * @return string 解決パス
     */
    private function resolveIncludePath(string $file, string $baseDir): string
    {
        // __DIR__ を模倣
        if (strpos($file, '__DIR__') !== false) {
            $file = str_replace('__DIR__', $baseDir, $file);
            return str_replace('//','/',$file);
        }
        // 絶対パス
        if (substr($file,0,1)==='/') {
            return $file;
        }
        // 相対パス候補
        $cands = [
            $baseDir.'/'.$file,
            $baseDir.'/includes/'.basename($file),
        ];
        foreach ($cands as $p) {
            if (file_exists($p)) {
                return $p;
            }
        }
        // デフォルト戻り
        return $baseDir.'/'.$file;
    }

    // =================================================================
    // CRUD 操作抽出
    // =================================================================

    /**
     * 生 SQL 文から SELECT/INSERT/UPDATE/DELETE を正規表現で検出し、
     * ファイルごとの CRUD 操作配列に保存
     *
     * @param string $content
     * @param string $filePath
     * @return array ['selects'=>[], 'inserts'=>[], 'updates'=>[], 'deletes'=>[]]
     */
    private function analyzeCrudOperations(string $content, string $filePath): array
    {
        $crud = ['selects'=>[],'inserts'=>[],'updates'=>[],'deletes'=>[]];

        // SELECT
        if (preg_match_all('/SELECT\s+.*?FROM\s+([^\s;]+)/i',$content,$m)) {
            foreach ($m[1] as $tbl) {
                $crud['selects'][] = trim(str_replace('`','',$tbl));
            }
        }
        // INSERT
        if (preg_match_all('/INSERT\s+INTO\s+([^\s;]+)/i',$content,$m)) {
            foreach ($m[1] as $tbl) {
                $crud['inserts'][] = trim(str_replace('`','',$tbl));
            }
        }
        // UPDATE
        if (preg_match_all('/UPDATE\s+([^\s;]+)/i',$content,$m)) {
            foreach ($m[1] as $tbl) {
                $crud['updates'][] = trim(str_replace('`','',$tbl));
            }
        }
        // DELETE
        if (preg_match_all('/DELETE\s+FROM\s+([^\s;]+)/i',$content,$m)) {
            foreach ($m[1] as $tbl) {
                $crud['deletes'][] = trim(str_replace('`','',$tbl));
            }
        }

        // 保存および返却
        $this->fileCrudOperations[$filePath] = $crud;
        return $crud;
    }

    // =================================================================
    // PHP AST ベース解析
    // =================================================================

    /**
     * php-parser を用いて AST 解析し、関数一覧・変数一覧・SQL クエリ等を抽出
     *
     * @param string $content
     * @return array ['queries'=>[], 'sql_queries'=>[], 'functions'=>[], 'variables'=>[], 'classes'=>[]]
     */
    public function analyzePhpContent(string $content): array
    {
        $res = ['queries'=>[],'sql_queries'=>[],'functions'=>[],'variables'=>[],'classes'=>[]];
        try {
            // 最新対応のパーサを生成
            $parser = (new ParserFactory())->createForNewestSupportedVersion();
            $ast    = $parser->parse($content);

            if ($ast !== null) {
                $tr = new NodeTraverser();
                $visitor = new PhpAstVisitor($this);
                // 名前解決と自作 Visitor
                $tr->addVisitor(new NameResolver());
                $tr->addVisitor($visitor);
                $tr->traverse($ast);

                // Visitor から取得
                $res['functions']   = $visitor->getFunctions();
                $res['variables']   = $visitor->getVariables();
                $res['queries']     = $visitor->getQueries();
                // クラス情報は FileAnalyzer 自身の配列に格納
                $res['classes']     = $this->classes;
            }

            // 生 SQL 検出(フォールバック)
            if (preg_match_all('/(?:SELECT|INSERT|UPDATE|DELETE)\s+.+?;/is',$content,$m)) {
                foreach ($m[0] as $q) {
                    $nq = $this->normalizeSqlQuery($q);
                    if ($nq) $res['sql_queries'][] = $nq;
                }
            }
        } catch (Exception $e) {
            // AST 解析失敗時はフォールバック
            $res = $this->fallbackParsePhp($content);
        }
        return $res;
    }

    // =================================================================
    // HTML 解析 (DOMDocument + DOMXPath)
    // =================================================================

    /**
     * HTML をパースし、<form> や <a>, <script>, <img> タグの URL を抽出
     *
     * @param string $content
     * @return array ['urls'=>[['type'=>..., 'url'=>...],...], 'success'=>bool, 'error'=>string|null]
     */
    public function analyzeHtmlContent(string $content): array
    {
        try {
            if (trim($content) === '') {
                return ['urls'=>[],'success'=>true,'error'=>null];
            }
            $dom = new DOMDocument();
            @$dom->loadHTML($content, LIBXML_NOERROR|LIBXML_NOWARNING);
            $xp  = new DOMXPath($dom);

            $urls = [];
            // form[action]
            foreach ($xp->query('//form[@action]') as $f) {
                /** @var \DOMElement $f */
                $urls[] = ['type'=>'form_action','url'=>$f->getAttribute('action')];
            }
            // a[href]
            foreach ($xp->query('//a[@href]') as $a) {
                /** @var \DOMElement $a */
                $urls[] = ['type'=>'link','url'=>$a->getAttribute('href')];
            }
            // script[src]
            foreach ($xp->query('//script[@src]') as $s) {
                /** @var \DOMElement $s */
                $urls[] = ['type'=>'script','url'=>$s->getAttribute('src')];
            }
            // img[src]
            foreach ($xp->query('//img[@src]') as $i) {
                /** @var \DOMElement $i */
                $urls[] = ['type'=>'image','url'=>$i->getAttribute('src')];
            }

            return ['urls'=>$urls,'success'=>true,'error'=>null];
        } catch (Exception $e) {
            return ['urls'=>[],'success'=>false,'error'=>$e->getMessage()];
        }
    }

    // =================================================================
    // 外部アクセス解析 (fetch/axios/XHR/リンク/フォーム etc.)
    // =================================================================

    /**
     * JS/HTML コンテンツから fetch/axios/.ajax/XMLHttpRequest など外部アクセスを検出
     *
     * @param string $content
     * @return array
     */
    public function analyzeExternalAccess(string $content): array
    {
        $out = [
            'api_calls'=>[], 'external_links'=>[], 'form_submissions'=>[],
            'ajax_requests'=>[], 'iframe_embeds'=>[], 'redirects'=>[],
            'dynamic_actions'=>[], 'dynamic_links'=>[], 'window_opens'=>[],
        ];
        try {
            // fetch(...)
            if (preg_match_all('/fetch\([\'"]([^\'"]+)[\'"]\)/',$content,$m)) {
                foreach ($m[1] as $u) {
                    $out['api_calls'][] = ['method'=>'fetch','url'=>$u,'line'=>$this->findLineNumber($content,$u)];
                }
            }
            // axios.get/post
            if (preg_match_all('/axios\.(get|post|put|delete)\([\'"]([^\'"]+)[\'"]\)/',$content,$m)) {
                foreach ($m[2] as $i=>$u) {
                    $out['api_calls'][] = ['method'=>$m[1][$i],'url'=>$u,'line'=>$this->findLineNumber($content,$u)];
                }
            }
            // $.ajax({url:...})
            if (preg_match_all('/\.ajax\(\s*{[^}]*url\s*:\s*[\'"]([^\'"]+)[\'"]/',$content,$m)) {
                foreach ($m[1] as $u) {
                    $out['api_calls'][] = ['method'=>'ajax','url'=>$u,'line'=>$this->findLineNumber($content,$u)];
                }
            }
            // XHR.open(...)
            if (preg_match_all('/new\s+XMLHttpRequest\(\)[^;]*\.open\([\'"]([^\'"]+)[\'"]\)/',$content,$m)) {
                foreach ($m[1] as $u) {
                    $out['api_calls'][] = ['method'=>'XMLHttpRequest','url'=>$u,'line'=>$this->findLineNumber($content,$u)];
                }
            }
            // <a href="http..."> external_links
            if (preg_match_all('/<a\s+href=[\'"](http[^\'"]+)[\'"]/', $content, $m)) {
                foreach ($m[1] as $u) {
                    $out['external_links'][] = ['url'=>$u,'line'=>$this->findLineNumber($content,$u)];
                }
            }
            // <form action="http...">
            if (preg_match_all('/<form\s+action=[\'"](http[^\'"]+)[\'"]/', $content, $m)) {
                foreach ($m[1] as $u) {
                    $out['form_submissions'][] = ['url'=>$u,'line'=>$this->findLineNumber($content,$u)];
                }
            }
            // iframe src
            if (preg_match_all('/<iframe\s+src=[\'"]([^\'"]+)[\'"]/', $content, $m)) {
                foreach ($m[1] as $u) {
                    $out['iframe_embeds'][] = ['url'=>$u,'line'=>$this->findLineNumber($content,$u)];
                }
            }
            // location.href
            if (preg_match_all('/location\.href\s*=\s*[\'"]([^\'"]+)[\'"]/', $content, $m)) {
                foreach ($m[1] as $u) {
                    $out['redirects'][] = ['url'=>$u,'line'=>$this->findLineNumber($content,$u)];
                }
            }
            // window.open(...)
            if (preg_match_all('/window\.open\([\'"]([^\'"]+)[\'"]\)/', $content, $m)) {
                foreach ($m[1] as $u) {
                    $out['window_opens'][] = ['url'=>$u,'line'=>$this->findLineNumber($content,$u)];
                }
            }
        } catch (Exception $e) {
            $this->logError('external_access_analysis','',0,$e->getMessage());
        }
        return $out;
    }

    /**
     * 指定文字列が現れる行番号を返す (なければ 0)
     *
     * @param string $content
     * @param string $search
     * @return int
     */
    private function findLineNumber(string $content, string $search): int
    {
        $lines = explode("\n", $content);
        foreach ($lines as $i=>$line) {
            if (strpos($line, $search)!==false) {
                return $i+1;
            }
        }
        return 0;
    }

    // =================================================================
    // 条件付きクエリパターン抽出 (simple regex)
    // =================================================================

    /**
     * if/else内で `$query = '...'` 形式の SQL を取り出し、
     * 条件とセットで返す
     *
     * @param string $content
     * @param string $filePath
     * @return array
     */
    private function analyzeConditionalQueries(string $content, string $filePath): array
    {
        $out = [];
        if (preg_match_all('/if\s*\((.*?)\)\s*{([^}]+)}(?:\s*else\s*{([^}]+)})?/is',$content,$m,PREG_SET_ORDER)) {
            foreach ($m as $blk) {
                $cond   = trim($blk[1]);
                $ifBody = $blk[2];
                $elseBody = $blk[3] ?? '';
                // if 部分
                if (preg_match_all('/\$query\s*=\s*[\'"](.+?)[\'"];/i',$ifBody,$qm)) {
                    foreach ($qm[1] as $q) {
                        $nq = $this->normalizeSqlQuery($q);
                        $out[] = ['conditions'=>[$cond],'query'=>$nq,'tables'=>$this->extractTableNames($nq),'file'=>$filePath];
                    }
                }
                // else 部分
                if (preg_match_all('/\$query\s*=\s*[\'"](.+?)[\'"];/i',$elseBody,$qm)) {
                    foreach ($qm[1] as $q) {
                        $nq = $this->normalizeSqlQuery($q);
                        $out[] = ['conditions'=>['else'],'query'=>$nq,'tables'=>$this->extractTableNames($nq),'file'=>$filePath];
                    }
                }
            }
        }
        return $out;
    }

    // =================================================================
    // SQL 正規化／テーブル抽出
    // =================================================================

    /**
     * SQL をフォーマット・大文字化し、末尾のセミコロンを除去
     *
     * @param string $query
     * @return string
     */
    public function normalizeSqlQuery(string $query): string
    {
        // 空白を正規化
        $q = preg_replace('/\s+/', ' ', trim($query));
        // コメント除去
        $q = preg_replace('/--.*$/m','',$q);
        $q = preg_replace('/\/\*.*?\*\//s','',$q);
        // キーワードを大文字化
        $keywords = ['SELECT','FROM','WHERE','INSERT','INTO','VALUES','UPDATE','SET','DELETE','JOIN'];
        foreach ($keywords as $kw) {
            $q = preg_replace('/\b'.preg_quote($kw,'/').'\b/i',$kw,$q);
        }
        // 末尾のセミコロンを除去
        return rtrim($q,';');
    }

    /**
     * normalizeSqlQuery 後の SQL から FROM/JOIN/UPDATE/INTO 部分のテーブル名を抽出
     *
     * @param string $sql
     * @return array テーブル名リスト
     */
    public function extractTableNames(string $sql): array
    {
        $tables = [];
        // FROM
        if (preg_match('/FROM\s+([`\w]+)/i',$sql,$m)) {
            $tables[] = str_replace('`','',$m[1]);
        }
        // JOIN
        if (preg_match_all('/JOIN\s+([`\w]+)/i',$sql,$m)) {
            foreach ($m[1] as $t) {
                $tables[] = str_replace('`','',$t);
            }
        }
        // UPDATE/INTO
        if (preg_match('/UPDATE\s+([`\w]+)/i',$sql,$m)) {
            $tables[] = str_replace('`','',$m[1]);
        }
        if (preg_match('/INTO\s+([`\w]+)/i',$sql,$m)) {
            $tables[] = str_replace('`','',$m[1]);
        }
        return array_unique($tables);
    }

    // =================================================================
    // フォールバック解析 (AST 失敗時・非対応拡張子)
    // =================================================================

    /**
     * SQL / 関数 / クラス / 変数 を正規表現で取り出す簡易版
     *
     * @param string $content
     * @return array
     */
    private function fallbackParse(string $content): array
    {
        $r = ['queries'=>[],'functions'=>[],'classes'=>[],'variables'=>[]];
        // SQL
        if (preg_match_all('/(?:SELECT|INSERT|UPDATE|DELETE)\s+.+?;/is',$content,$m)) {
            foreach ($m[0] as $q) {
                $r['queries'][] = $this->normalizeSqlQuery($q);
            }
        }
        // 関数
        if (preg_match_all('/function\s+([a-zA-Z_]\w*)\s*\(/',$content,$m)) {
            $r['functions'] = $m[1];
        }
        // クラス
        if (preg_match_all('/class\s+([a-zA-Z_]\w*)/',$content,$m)) {
            $r['classes'] = $m[1];
        }
        // 変数
        if (preg_match_all('/\$([a-zA-Z_]\w*)\s*=/',$content,$m)) {
            $r['variables'] = $m[1];
        }
        return $r;
    }

    // =================================================================
    // Excel 出力
    // =================================================================

    /**
     * 解析結果を Excel (.xlsx) に書き出す
     *
     * @param string $outputPath 保存先ファイルパス
     */
    public function exportToExcel(string $outputPath): void
    {
        $ss = new Spreadsheet();

        // --- ビューシート ---
        $view = $ss->getActiveSheet();
        $view->setTitle('ビュー');
        $view->setCellValue('A1','ビュー名');
        $view->setCellValue('B1','テーブル');
        $view->setCellValue('C1','CRUD');
        $row = 2;
        foreach ($this->views as $v) {
            $view->setCellValue("A{$row}", $v['name']);
            $view->setCellValue("B{$row}", implode(', ',$v['tables'] ?? []));
            $view->setCellValue("C{$row}", implode(', ',$v['crud_operations']['selects'] ?? []));
            $row++;
        }

        // --- ストアドプロシージャシート ---
        $proc = $ss->createSheet();
        $proc->setTitle('ストアドプロシージャ');
        $proc->setCellValue('A1','プロシージャ名');
        $proc->setCellValue('B1','パラメータ');
        $proc->setCellValue('C1','CRUD');
        $row = 2;
        foreach ($this->storedProcedures as $p) {
            $proc->setCellValue("A{$row}", $p['name']);
            $params = array_map(fn($x)=>$x['name'].'('.$x['type'].')',$p['parameters'] ?? []);
            $proc->setCellValue("B{$row}", implode(', ',$params));
            $ops = [];
            foreach (['selects','inserts','updates','deletes'] as $op) {
                if (!empty($p['crud_operations'][$op])) {
                    $ops[] = strtoupper($op).':'.implode(', ',$p['crud_operations'][$op]);
                }
            }
            $proc->setCellValue("C{$row}", implode('; ',$ops));
            $row++;
        }

        // --- ファイル別 CRUD 操作シート ---
        $fcrud = $ss->createSheet();
        $fcrud->setTitle('ファイル別CRUD操作');
        $fcrud->setCellValue('A1','ファイル');
        $fcrud->setCellValue('B1','テーブル');
        $fcrud->setCellValue('C1','操作');
        $row = 2;
        foreach ($this->fileCrudOperations as $file=>$crud) {
            foreach (['selects'=>'SELECT','inserts'=>'INSERT','updates'=>'UPDATE','deletes'=>'DELETE'] as $key=>$label) {
                foreach ($crud[$key] as $tbl) {
                    $fcrud->setCellValue("A{$row}", $file);
                    $fcrud->setCellValue("B{$row}", $tbl);
                    $fcrud->setCellValue("C{$row}", $label);
                    $row++;
                }
            }
        }

        // --- 条件付きパターンシート ---
        $pat = $ss->createSheet();
        $pat->setTitle('条件分岐パターン');
        $pat->setCellValue('A1','条件');
        $pat->setCellValue('B1','クエリ');
        $pat->setCellValue('C1','テーブル');
        $row = 2;
        foreach ($this->conditionalPatterns as $pattern) {
            $pat->setCellValue("A{$row}", implode(' AND ',$pattern['conditions']));
            $pat->setCellValue("B{$row}", $pattern['query']);
            $pat->setCellValue("C{$row}", implode(', ',$pattern['tables'] ?? []));
            $row++;
        }

        // ファイル保存
        $writer = new Xlsx($ss);
        $writer->save($outputPath);
    }
}

// -------------------------------------------------------------
// PhpAstVisitor クラス
// php-parser のノードを巡回し、SQL クエリや関数定義を抽出
// -------------------------------------------------------------
class PhpAstVisitor extends NodeVisitorAbstract
{
    protected FileAnalyzer $analyzer;
    protected ?string $currentFunction = null;
    protected array $currentConditions = [];
    protected array $functions = [];
    protected array $variables = [];
    protected array $queries = [];

    public function __construct(FileAnalyzer $analyzer)
    {
        $this->analyzer = $analyzer;
    }

    public function enterNode(Node $node)
    {
        // クラス定義
        if ($node instanceof Node\Stmt\Class_) {
            $this->analyzer->classes[] = [
                'name'    => $node->name->toString(),
                'methods' => []
            ];
        }
        // メソッド定義
        if ($node instanceof Node\Stmt\ClassMethod) {
            $fn = $node->name->toString();
            $this->currentFunction = $fn;
            // クラスメソッドは FileAnalyzer::$classes に追加済み
        }
        // 関数定義 (グローバル関数)
        if ($node instanceof Node\Stmt\Function_) {
            $name = $node->name->toString();
            $this->functions[] = [
                'name' => $name,
                'file' => $this->analyzer->currentFile,
                'params'=> array_map(fn($p)=>$p->var->name,$node->params)
            ];
            $this->currentFunction = $name;
        }
        // if 条件
        if ($node instanceof Node\Stmt\If_) {
            $cond = $this->evaluateCondition($node->cond);
            $this->currentConditions[] = $cond;
        }
        // 代入式の中に文字列 SQL があれば抽出
        if ($node instanceof Node\Expr\Assign && $node->expr instanceof Node\Scalar\String_) {
            $sql = $this->analyzer->extractSqlFromString($node->expr->value);
            if ($sql) {
                $this->queries[] = $sql;
                $tables = $this->analyzer->extractTableNames($sql);
                $this->analyzer->conditionalPatterns[] = [
                    'conditions'=> $this->currentConditions,
                    'query'     => $sql,
                    'tables'    => $tables
                ];
            }
        }
    }

    public function leaveNode(Node $node)
    {
        if ($node instanceof Node\Stmt\If_) {
            array_pop($this->currentConditions);
        }
        if ($node instanceof Node\Stmt\Function_ || $node instanceof Node\Stmt\ClassMethod) {
            $this->currentFunction = null;
        }
    }

    /**
     * AST の条件式ノードから文字列化して返す
     */
    private function evaluateCondition(Node $node): string
    {
        if ($node instanceof Node\Expr\BinaryOp) {
            return $this->evaluateCondition($node->left)
                 . ' ' . $node->getOperatorSigil() . ' '
                 . $this->evaluateCondition($node->right);
        }
        if ($node instanceof Node\Expr\Variable) {
            return '$'.$node->name;
        }
        if ($node instanceof Node\Scalar\String_) {
            return '"'.$node->value.'"';
        }
        if ($node instanceof Node\Scalar\LNumber || $node instanceof Node\Scalar\DNumber) {
            return (string)$node->value;
        }
        return 'expr';
    }

    /**
     * Visitor が収集した関数一覧を返す
     */
    public function getFunctions(): array
    {
        return $this->functions;
    }

    /**
     * Visitor が収集した変数一覧を返す
     */
    public function getVariables(): array
    {
        return $this->variables;
    }

    /**
     * Visitor が収集したクエリ一覧を返す
     */
    public function getQueries(): array
    {
        return $this->queries;
    }
}