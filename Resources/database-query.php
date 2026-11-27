<?php
declare(strict_types=1);

try {
    $request = json_decode(stream_get_contents(STDIN), true, flags: JSON_THROW_ON_ERROR);
    $connection = $request['connection'];
    if (!extension_loaded('pdo_mysql')) {
        throw new RuntimeException('PHP needs the pdo_mysql extension.');
    }
    $db = new PDO(
        'mysql:host=127.0.0.1;port=' . $connection['port'] .
        ';dbname=' . $connection['database'] . ';charset=utf8mb4',
        $connection['user'],
        $connection['password'],
        [
            PDO::ATTR_EMULATE_PREPARES => false,
            PDO::ATTR_TIMEOUT => 5,
            PDO::MYSQL_ATTR_MULTI_STATEMENTS => false,
            PDO::MYSQL_ATTR_LOCAL_INFILE => false,
            PDO::MYSQL_ATTR_USE_BUFFERED_QUERY => false,
        ]
    );
    $db->exec('SET SESSION max_execution_time = 10000');
    $db->exec('START TRANSACTION READ ONLY');
    $statement = $db->query($request['sql']);
    $columns = [];
    for ($index = 0; $index < $statement->columnCount(); $index++) {
        $columns[] = $statement->getColumnMeta($index)['name'];
    }
    $rows = [];
    $bytes = 0;
    $truncated = false;
    while ($row = $statement->fetch(PDO::FETCH_NUM)) {
        foreach ($row as &$value) {
            if (is_string($value) && strlen($value) > 4096) {
                $value = substr($value, 0, 4096) . '…';
                $truncated = true;
            }
        }
        unset($value);
        $bytes += strlen(json_encode($row, JSON_INVALID_UTF8_SUBSTITUTE | JSON_THROW_ON_ERROR));
        if (count($rows) >= 200 || $bytes > 1024 * 1024) {
            $truncated = true;
            break;
        }
        $rows[] = $row;
    }
    echo json_encode(compact('columns', 'rows', 'truncated'), JSON_INVALID_UTF8_SUBSTITUTE | JSON_THROW_ON_ERROR);
} catch (Throwable $error) {
    echo json_encode(['error' => $error->getMessage()], JSON_INVALID_UTF8_SUBSTITUTE);
}
