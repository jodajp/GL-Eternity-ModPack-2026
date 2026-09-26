Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web

# ==========================================
# 0. IMPLEMENTAÇÃO EM C# DO CURSEFORGE MURMUR2
# ==========================================
Add-Type -TypeDefinition @"
using System;
using System.IO;

public static class CurseMurmurHash
{
    private const uint M = 0x5bd1e995;
    private const int R = 24;

    public static uint Compute(string filePath)
    {
        byte[] buffer = File.ReadAllBytes(filePath);
        
        // Passo 1: Filtrar caracteres whitespace conforme a norma CurseForge
        int length = 0;
        for (int i = 0; i < buffer.Length; i++)
        {
            byte b = buffer[i];
            if (b != 0x9 && b != 0xa && b != 0xd && b != 0x20)
            {
                buffer[length++] = b;
            }
        }

        // Passo 2: Murmur2 com seed = 1
        uint h = 1u ^ (uint)length;
        int currentIndex = 0;

        while (length >= 4)
        {
            uint k = BitConverter.ToUInt32(buffer, currentIndex);
            k *= M;
            k ^= k >> R;
            k *= M;

            h *= M;
            h ^= k;

            currentIndex += 4;
            length -= 4;
        }

        switch (length)
        {
            case 3:
                h ^= (uint)(buffer[currentIndex + 2] << 16);
                goto case 2;
            case 2:
                h ^= (uint)(buffer[currentIndex + 1] << 8);
                goto case 1;
            case 1:
                h ^= buffer[currentIndex];
                h *= M;
                break;
        }

        h ^= h >> 13;
        h *= M;
        h ^= h >> 15;

        return h;
    }
}
"@

# ==========================================
# 1. CONFIGURAÇÕES
# ==========================================
$repo = "jodajp/GL-Eternity-ModPack-2026"
$tag = "latest"
$modsFolder = [System.IO.Path]::Combine(($PSScriptRoot), "mods")
$contentJsonPath = [System.IO.Path]::Combine(($PSScriptRoot), "automodpack-content.json")

if (-not [System.IO.Directory]::Exists($modsFolder)) {
    Write-Error "Pasta de mods nao encontrada: $modsFolder"
    return
}

$token = (gh auth token 2>$null)
if (-not $token) {
    Write-Error "Token do GitHub nao encontrado. Executa 'gh auth login' primeiro."
    return
}

$httpClient = [System.Net.Http.HttpClient]::new()
$httpClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", ($token))
$httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("GL-Pack-Sync-Script")
$httpClient.Timeout = [System.TimeSpan]::FromMinutes(5)

try {
    # ==========================================
    # 2. GERAR automodpack-content.json LOCAL
    # ==========================================
    Write-Host "A calcular hashes SHA-1 e Murmur2 de todos os mods..." -ForegroundColor Cyan

    $jarFiles = [System.IO.Directory]::GetFiles(($modsFolder), "*.jar")
    $localFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $listEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
    $sha1Managed = [System.Security.Cryptography.SHA1]::Create()

    for ($i = 0; $i -lt $jarFiles.Length; $i++) {
        $filePath = $jarFiles[$i]
        $fileName = [System.IO.Path]::GetFileName($filePath)
        $fileInfo = [System.IO.FileInfo]::new($filePath)

        try {
            # SHA-1
            $stream = [System.IO.File]::OpenRead($filePath)
            $shaBytes = $sha1Managed.ComputeHash($stream)
            $stream.Close()
            $stream.Dispose()
            $sha1Hex = [System.BitConverter]::ToString($shaBytes).Replace("-", "").ToLower()

            # Murmur2 (CurseForge)
            $murmurVal = [CurseMurmurHash]::Compute($filePath)

            $listEntries.Add([PSCustomObject]@{
                file = "/mods/$fileName"
                size = [string]$fileInfo.Length
                type = "mod"
                editable = $false
                forceCopy = $true
                sha1 = $sha1Hex
                murmur = [string]$murmurVal
            })

            $null = $localFileNames.Add($fileName)
        } catch {
            Write-Warning "Falha ao processar ${fileName}: $_"
        }
    }
    $sha1Managed.Dispose()

    # Estrutura oficial do AutoModpack v4
    $autoModpackManifest = [PSCustomObject]@{
        modpackName = "GL-Eternity-2026"
        automodpackVersion = "4.0.5"
        loader = "neoforge"
        loaderVersion = "21.1.250"
        mcVersion = "1.21.1"
        list = $listEntries
    }

    $jsonOutput = $autoModpackManifest | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText(($contentJsonPath), $jsonOutput, [System.Text.Encoding]::UTF8)

    Write-Host "Ficheiro automodpack-content.json gerado com sucesso ($($listEntries.Count) mods)!" -ForegroundColor Green

    # ==========================================
    # 3. MAPEAMENTO DOS ASSETS REMOTOS NO GITHUB
    # ==========================================
    Write-Host "`nA mapear assets remotos da Release..." -ForegroundColor Cyan

    $relData = (gh api ("repos/" + $repo + "/releases/tags/" + $tag) | ConvertFrom-Json)
    $releaseNumericId = $relData.id

    $remoteAssets = @{}
    $page = 1

    while ($true) {
        $endpoint = "repos/" + $repo + "/releases/" + $releaseNumericId + "/assets?per_page=100&page=" + $page
        $jsonText = (gh api $endpoint 2>$null)
        if (-not $jsonText) { break }

        $pageItems = ($jsonText | ConvertFrom-Json)
        $itemsArray = @($pageItems)
        if ($itemsArray.Length -eq 0) { break }

        for ($idx = 0; $idx -lt $itemsArray.Length; $idx++) {
            $singleAsset = $itemsArray[$idx]
            if ($singleAsset.name -and $singleAsset.id) {
                $remoteAssets[[string]$singleAsset.name] = [string]$singleAsset.id
            }
        }

        if ($itemsArray.Length -lt 100) { break }
        $page++
    }

    Write-Host "Release ID: $releaseNumericId | Assets no GitHub: $($remoteAssets.Count)" -ForegroundColor Green

    # ==========================================
    # 4. PURGA DE FICHEIROS OBSOLETOS
    # ==========================================
    Write-Host "`nA verificar ficheiros obsoletos para remover..." -ForegroundColor Cyan
    $deletedCount = 0
    $assetNames = [string[]]($remoteAssets.Keys)

    for ($idx = 0; $idx -lt $assetNames.Length; $idx++) {
        $assetName = $assetNames[$idx]

        if ($assetName.EndsWith(".jar", [System.StringComparison]::OrdinalIgnoreCase)) {
            if (-not $localFileNames.Contains($assetName)) {
                $assetId = $remoteAssets[$assetName]
                Write-Host "A remover versao antiga: $assetName" -ForegroundColor Red
                
                try {
                    $deleteUrl = "https://api.github.com/repos/$repo/releases/assets/$assetId"
                    $delResp = $httpClient.DeleteAsync($deleteUrl).GetAwaiter().GetResult()
                    if ($delResp.IsSuccessStatusCode) {
                        $deletedCount++
                        $remoteAssets.Remove($assetName)
                    }
                } catch {
                    Write-Warning "Erro ao apagar ${assetName}: $_"
                }
            }
        }
    }

    # ==========================================
    # 5. UPLOAD DO automodpack-content.json PARA O GITHUB
    # ==========================================
    Write-Host "`nA carregar automodpack-content.json para a Release..." -ForegroundColor Yellow
    gh release upload ($tag) ($contentJsonPath) --repo ($repo) --clobber

    # ==========================================
    # 6. UPLOAD DELTA DOS MODS .JAR
    # ==========================================
    Write-Host "`nA sincronizar novos mods..." -ForegroundColor Cyan
    $total = $jarFiles.Length
    $current = 0
    $uploadedCount = 0

    for ($i = 0; $i -lt $jarFiles.Length; $i++) {
        $current++
        $filePath = $jarFiles[$i]
        $fileName = [System.IO.Path]::GetFileName($filePath)

        if ($remoteAssets.ContainsKey($fileName)) {
            Write-Host "[$current/$total] Ja existe: $fileName" -ForegroundColor DarkGray
            continue
        }

        Write-Host "[$current/$total] A enviar: $fileName" -ForegroundColor Green

        try {
            $encodedName = [System.Uri]::EscapeDataString($fileName)
            $uploadUrl = "https://uploads.github.com/repos/$repo/releases/$releaseNumericId/assets?name=$encodedName"

            $fileStream = [System.IO.File]::OpenRead($filePath)
            $content = [System.Net.Http.StreamContent]::new($fileStream)
            $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("application/java-archive")

            $response = $httpClient.PostAsync($uploadUrl, $content).GetAwaiter().GetResult()

            $fileStream.Close()
            $fileStream.Dispose()
            $content.Dispose()

            if ($response.IsSuccessStatusCode) {
                $uploadedCount++
                $remoteAssets[$fileName] = 0
            } else {
                Write-Warning "Falha no envio de $fileName"
            }
        } catch {
            Write-Warning "Excecao ao enviar ${fileName}: $_"
        }
    }

    Write-Host "`nProcesso concluido!" -ForegroundColor Green
    Write-Host "Mods processados: $total | Novos enviados: $uploadedCount \vert{} Obsoletos removidos:$deletedCount" -ForegroundColor Cyan

} finally {
    $httpClient.Dispose()
}