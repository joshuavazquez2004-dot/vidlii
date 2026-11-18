<?php
/**
 * Vidara.so video storage adapter.
 *
 * Videos are uploaded to Vidara and played back from Vidara's embed, so the
 * application never has to keep large media files on local disk.
 *
 * API notes (verified against the live service, not just the published docs):
 *   - The multipart upload field for the key is `api_key`; the docs say `key`,
 *     which the server rejects with HTTP 401 {"error":"Missing API key"}.
 *   - The upload server is discovered from /v1/upload/server and can move, so it
 *     is resolved at runtime instead of being hard-coded.
 *   - A successful upload returns {"filecode":"https://vidara.to/e/CODE", ...},
 *     i.e. `filecode` is an embed URL, and the bare code is what the other
 *     endpoints expect.
 */
class VidaraStorage
{
    const API_BASE = 'https://api.vidara.so/v1';
    const FALLBACK_UPLOAD_SERVER = 'https://s1.vidara.so/api/upload';

    /** @var string */
    private $Key;
    /** @var string|null */
    private $UploadServer;
    /** @var string|null */
    private $LastError;

    function __construct(?string $Key = null)
    {
        $this->Key = $Key !== null ? trim($Key) : self::env('VIDARA_API');
    }

    /**
     * Read a configuration value from the runtime environment.
     * AppJet injects Settings variables outside Git, so nothing is hard-coded here.
     */
    public static function env(string $Name): string
    {
        $Value = $_ENV[$Name] ?? $_SERVER[$Name] ?? getenv($Name);
        return is_string($Value) ? trim($Value) : '';
    }

    function isConfigured(): bool
    {
        return $this->Key !== '';
    }

    function lastError(): ?string
    {
        return $this->LastError;
    }

    /** Extract the bare file code from an embed URL or a raw code. */
    public static function codeFrom(string $Value): string
    {
        $Value = trim($Value);
        if (preg_match('~/e/([A-Za-z0-9]+)~', $Value, $Match)) {
            return $Match[1];
        }
        if (preg_match('~^[A-Za-z0-9]{6,32}$~', $Value)) {
            return $Value;
        }
        return '';
    }

    /**
     * Perform an API call. Returns the decoded response, or null on failure
     * with the reason kept in lastError().
     */
    private function request(string $Method, string $Url, array $Fields = [], array $Files = []): ?array
    {
        if (!$this->isConfigured()) {
            $this->LastError = 'VIDARA_API is not configured';
            return null;
        }

        $Handle = curl_init($Url);
        $Options = [
            CURLOPT_RETURNTRANSFER => true,
            // Video uploads can legitimately take several minutes.
            CURLOPT_TIMEOUT        => 1800,
            CURLOPT_CONNECTTIMEOUT => 20,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_MAXREDIRS      => 3,
        ];

        if ($Method === 'POST') {
            $Body = $Fields;
            foreach ($Files as $Field => $Path) {
                if (!is_file($Path) || filesize($Path) === 0) {
                    $this->LastError = "file is missing or empty: $Path";
                    curl_close($Handle);
                    return null;
                }
                $Body[$Field] = new CURLFile($Path, mime_content_type($Path) ?: 'application/octet-stream', basename($Path));
            }
            $Options[CURLOPT_POST]       = true;
            $Options[CURLOPT_POSTFIELDS] = $Body;
        }

        curl_setopt_array($Handle, $Options);
        $Raw    = curl_exec($Handle);
        $Status = (int) curl_getinfo($Handle, CURLINFO_HTTP_CODE);
        $Error  = curl_error($Handle);
        curl_close($Handle);

        if ($Raw === false) {
            $this->LastError = "network error: $Error";
            return null;
        }

        $Json = json_decode($Raw, true);
        if (!is_array($Json)) {
            $this->LastError = "unexpected response (HTTP $Status): " . substr(strip_tags((string) $Raw), 0, 200);
            return null;
        }

        $Reported = isset($Json['status']) ? (int) $Json['status'] : $Status;
        if ($Status >= 400 || $Reported >= 400) {
            $Message = $Json['error'] ?? $Json['msg'] ?? "HTTP $Status";
            $this->LastError = is_string($Message) ? $Message : "HTTP $Status";
            return null;
        }

        return $Json;
    }

    /** Resolve (and cache) the current upload endpoint. */
    function uploadServer(): string
    {
        if ($this->UploadServer !== null) {
            return $this->UploadServer;
        }

        $Response = $this->request('GET', self::API_BASE . '/upload/server?api_key=' . urlencode($this->Key));
        $Server   = $Response['result']['upload_server'] ?? '';

        $this->UploadServer = $Server !== '' ? $Server : self::FALLBACK_UPLOAD_SERVER;
        return $this->UploadServer;
    }

    /**
     * Upload a local video file to Vidara.
     *
     * @return array|null ['code' => string, 'embed' => string, 'video_id' => mixed]
     */
    function uploadVideo(string $Path): ?array
    {
        $Response = $this->request('POST', $this->uploadServer(), ['api_key' => $this->Key], ['file' => $Path]);
        if ($Response === null) {
            return null;
        }

        $Embed = (string) ($Response['filecode'] ?? '');
        $Code  = self::codeFrom($Embed);
        if ($Code === '') {
            $this->LastError = 'upload response did not contain a file code';
            return null;
        }

        return [
            'code'     => $Code,
            'embed'    => $Embed !== '' && strpos($Embed, 'http') === 0 ? $Embed : "https://vidara.to/e/$Code",
            'video_id' => $Response['video_id'] ?? null,
        ];
    }

    /** Fetch metadata (title, length, thumbnail URL) for a stored video. */
    function fileInfo(string $Code): ?array
    {
        $Response = $this->request(
            'GET',
            self::API_BASE . '/video/info?api_key=' . urlencode($this->Key) . '&filecode=' . urlencode($Code)
        );
        if ($Response === null) {
            return null;
        }

        $Result = $Response['result'] ?? null;
        if (is_array($Result) && isset($Result[0]) && is_array($Result[0])) {
            return $Result[0];
        }
        return is_array($Result) ? $Result : null;
    }

    /** Remove a video from Vidara (used when a user deletes their video). */
    function deleteVideo(string $Code): bool
    {
        if ($Code === '') {
            return false;
        }
        return $this->request(
            'GET',
            self::API_BASE . '/video/delete?api_key=' . urlencode($this->Key) . '&filecode=' . urlencode($Code)
        ) !== null;
    }

    /** Download a remote thumbnail so it can be stored in the database as before. */
    function fetchThumbnail(string $Url): ?string
    {
        if ($Url === '' || strpos($Url, 'http') !== 0) {
            return null;
        }

        $Handle = curl_init($Url);
        curl_setopt_array($Handle, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 60,
            CURLOPT_CONNECTTIMEOUT => 15,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_MAXREDIRS      => 3,
        ]);
        $Data   = curl_exec($Handle);
        $Status = (int) curl_getinfo($Handle, CURLINFO_HTTP_CODE);
        curl_close($Handle);

        if ($Data === false || $Status >= 400 || strlen($Data) < 128) {
            return null;
        }
        return $Data;
    }
}
