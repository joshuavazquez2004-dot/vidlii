<?php
    /**
     * Vidara storage helpers, shared by the web pages and the storage worker.
     */
    require_once __DIR__ . "/_classes/VidaraStorage.class.php";

    function vidara_storage(): VidaraStorage {
        static $Storage = null;
        if ($Storage === null) {
            $Storage = new VidaraStorage();
        }
        return $Storage;
    }

    /**
     * Return the Vidara embed URL for a video, or an empty string when the
     * video is not stored there (e.g. a locally hosted upload).
     */
    function vidara_embed_for(string $Video_URL, $DB = null): string {
        static $Cache = [];

        if (array_key_exists($Video_URL, $Cache)) {
            return $Cache[$Video_URL];
        }

        $Embed = "";
        if ($DB === null && isset($GLOBALS["DB"])) {
            $DB = $GLOBALS["DB"];
        }

        if ($DB && preg_match('/^[A-Za-z0-9]{11}$/', $Video_URL)) {
            try {
                $Row = $DB->execute("SELECT vidara_embed FROM videos WHERE url = :URL", true, [":URL" => $Video_URL]);
                if (!empty($Row["vidara_embed"])) {
                    $Embed = (string) $Row["vidara_embed"];
                }
            } catch (\Throwable $e) {
                // Column missing on a database that predates Vidara support.
                $Embed = "";
            }
        }

        $Cache[$Video_URL] = $Embed;
        return $Embed;
    }
