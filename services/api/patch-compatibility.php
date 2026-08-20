<?php

// doctrine/dbal 4.x removed getName() from every Platform class, but ~90 of the
// old (pre-2022) migrations in this repo still call
//   $this->connection->getDatabasePlatform()->getName() !== 'mysql'
// as a safety guard, which throws instead of skipping. Rewrite it to the
// DBAL-4-recommended instanceof check, which is true for MySQL *and* every
// MariaDB platform subclass alike -- matching the guard's original intent.
$old = "\$this->connection->getDatabasePlatform()->getName() !== 'mysql'";
$new = "!(\$this->connection->getDatabasePlatform() instanceof \\Doctrine\\DBAL\\Platforms\\AbstractMySQLPlatform)";

$patched = 0;
$untransactionalized = 0;
$detransactionalized = 0;
foreach (glob(__DIR__ . '/migrations/*.php') as $file) {
    $contents = file_get_contents($file);
    $changed = false;

    if (str_contains($contents, $old)) {
        $contents = str_replace($old, $new, $contents);
        $changed = true;
        $patched++;
    }

    // MySQL/MariaDB DDL (ALTER TABLE, ...) implicitly commits, which silently
    // invalidates the SAVEPOINT doctrine/migrations sets up around a
    // transactional migration. Migrations that mix DDL in up() with a
    // postUp()/postDown() data-fixup hook then crash with "SAVEPOINT ...
    // does not exist" once the post-hook (or migrationEnd's cleanup) tries to
    // use that savepoint. Disabling the transactional wrapper is doctrine's
    // own documented escape hatch for exactly this situation -- MySQL DDL
    // can't be rolled back by a transaction anyway, so wrapping it in one
    // never bought us anything.
    if (
        (str_contains($contents, 'function postUp(') || str_contains($contents, 'function postDown('))
        && !str_contains($contents, 'function isTransactional(')
    ) {
        $contents = preg_replace(
            '/(extends AbstractMigration\s*\n\{\s*\n)/',
            "$1    public function isTransactional(): bool\n    {\n        return false;\n    }\n\n",
            $contents,
            1,
            $count
        );
        if ($count > 0) {
            $changed = true;
            $untransactionalized++;
        }
    }

    // Some post-hooks additionally wrap their own row-fixup loop in an
    // explicit beginTransaction()/commit() pair. DBAL's nested-transaction
    // emulation tracks nesting in PHP, not in MySQL -- once the preceding DDL
    // implicitly committed underneath it, this explicit begin/commit pair
    // desyncs from reality and blows up the same way. These fixups only ever
    // touch rows that exist from a prior installation (a fresh install has an
    // empty table here, so the loop body is a no-op either way), so dropping
    // the transaction wrapper is safe.
    $withoutTx = preg_replace(
        '/[ \t]*\$this->connection->(?:beginTransaction|commit)\(\);\r?\n/',
        '',
        $contents,
        -1,
        $txCount
    );
    if ($txCount > 0) {
        $contents = $withoutTx;
        $changed = true;
        $detransactionalized += $txCount;
    }

    if ($changed) {
        file_put_contents($file, $contents);
    }
}

fwrite(STDERR, "patch-compatibility: rewrote $patched migration file(s) for doctrine/dbal 4.x compatibility, disabled transactional wrapping on $untransactionalized migration(s) with post-hooks, stripped $detransactionalized explicit begin/commit call(s).\n");

// app/commands/runtimes/RuntimeImport.php (the `runtimes:import` CLI command)
// declares its own -s/--silent option, which collides with a --silent option
// the console Application itself already registers globally on this
// symfony/console version -- "An option named "silent" already exists.",
// thrown at command registration time, before it ever gets to run. The
// command's own $input->getOption('silent') still resolves fine against the
// global one once the local (redundant) declaration is gone.
$runtimeImportFile = __DIR__ . '/app/commands/runtimes/RuntimeImport.php';
$contents = file_get_contents($runtimeImportFile);
$fixedContents = preg_replace(
    '/\)->addOption\(\s*\'silent\',\s*\'s\',\s*InputOption::VALUE_NONE,\s*"Silent mode \(no outputs except for errors\)"\s*\);/',
    ');',
    $contents,
    1,
    $runtimeImportCount
);
if ($runtimeImportCount > 0) {
    file_put_contents($runtimeImportFile, $fixedContents);
}
fwrite(STDERR, "patch-compatibility: removed colliding --silent option from RuntimeImport.php: " . ($runtimeImportCount > 0 ? "done" : "NOT FOUND (check upstream diff)") . "\n");
