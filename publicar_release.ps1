<#
==============================================================================
Script de Sincronizacao & Publicacao do AutoModpack para GitHub Releases
Repositorio: jodajp/GL-Eternity-ModPack-2026 | Tag: latest
==============================================================================
Funcionalidades Avancadas:
  1. Comparacao Inteligente: Faz upload APENAS dos ficheiros que faltam na Release.
  2. Multi-Pasta: Suporta mods (.jar), scripts KubeJS, configs e resourcepacks.
  3. Geracao Dupla de Manifestos:
     - automodpack-content.json (SHA-1 + Murmur2 CurseForge em C#)
     - automodpack-index.json (SHA-256 oficial do AutoModpack v4)
  4. Upload seguro via CLI oficial GitHub ('gh release upload') com retries.
  5. Purga Inteligente de Assets Obsoletos.
  6. Suporte a Parametros (-AutoCommit / -SkipPurge).
==============================================================================
#>

[CmdletBinding()]
param(
    [string]$Repo = "jodajp/GL-Eternity-ModPack-2026",
    [string]$Tag = "latest",
    [switch]$AutoCommit,
    [switch]$SkipPurge
)

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web

# ============================================================================
# 0. IMPLEMENTACAO EM C# DO CURSEFORGE MURMUR2 (NORMA OFICIAL)
# ============================================================================
if (-not ([System.Management.Automation.PSTypeName]'CurseMurmurHash').Type) {
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
            
            // Filtrar whitespace conforme especificacao CurseForge
            int length = 0;
            for (int i = 0; i < buffer.Length; i++)
            {
                byte b = buffer[i];
                if (b != 0x9 && b != 0xa && b != 0xd && b != 0x20)
                {
                    buffer[length++] = b;
                }
            }

            // Murmur2 com seed = 1
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
}

# ============================================================================
# 1. VALIDACAO DE AMBIENTE & CONFIGURACOES
# ============================================================================
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Get-Location }

$modsFolder = Join-Path $scriptRoot "mods"
$kubejsFolder = Join-Path $scriptRoot "kubejs"
$configFolder = Join-Path $scriptRoot "config"
$resourcepacksFolder = Join-Path $scriptRoot "resourcepacks"

$contentJsonPath = Join-Path $scriptRoot "automodpack-content.json"
$indexJsonPath = Join-Path $scriptRoot "automodpack-index.json"
$deletionsHistoryPath = Join-Path $scriptRoot "automodpack-deletions-history.json"

Write-Host "=================================================================" -ForegroundColor DarkCyan
Write-Host "   Sincronizador de Modpack & GitHub Releases (AutoModpack)      " -ForegroundColor Cyan
Write-Host "   Repositorio: $Repo | Tag: $Tag" -ForegroundColor DarkGray
Write-Host "=================================================================" -ForegroundColor DarkCyan

$token = (gh auth token 2>$null)
if (-not $token) {
    Write-Error "Token do GitHub nao encontrado. Executa 'gh auth login' primeiro."
    return
}

$httpClient = [System.Net.Http.HttpClient]::new()
$httpClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $token)
$httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("GL-Eternity-Sync-Engine/2.0")
$httpClient.Timeout = [System.TimeSpan]::FromMinutes(10)

# ============================================================================
# 2. VARREDURA DE FICHEIROS LOCAIS & CALCULO DE HASHES
# ============================================================================
Write-Host "`nA verificar pastas e calcular hashes (SHA-1, SHA-256, Murmur2)..." -ForegroundColor Cyan

$localFilesToSync = [System.Collections.Generic.List[PSCustomObject]]::new()
$localAssetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Registar-FicheiroLocal {
    param (
        [string]$FullPath,
        [string]$RelativeVirtualPath,
        [string]$AssetUploadName,
        [string]$Type
    )
    $fileInfo = [System.IO.FileInfo]::new($FullPath)
    if (-not $fileInfo.Exists -or $fileInfo.Length -eq 0) { return }

    $localFilesToSync.Add([PSCustomObject]@{
        FullPath = $FullPath
        FileName = $fileInfo.Name
        AssetUploadName = $AssetUploadName
        RelativeVirtualPath = $RelativeVirtualPath
        Size = $fileInfo.Length
        Type = $Type
    })
    $null = $localAssetNames.Add($AssetUploadName)
}

# A) Mods (.jar)
if ([System.IO.Directory]::Exists($modsFolder)) {
    $jars = [System.IO.Directory]::GetFiles($modsFolder, "*.jar", [System.IO.SearchOption]::AllDirectories)
    foreach ($j in $jars) {
        $fn = [System.IO.Path]::GetFileName($j)
        Registar-FicheiroLocal -FullPath $j -RelativeVirtualPath "/mods/$fn" -AssetUploadName $fn -Type "mod"
    }
}

# B) KubeJS Client Scripts (.js)
if ([System.IO.Directory]::Exists($kubejsFolder)) {
    $kjsFiles = [System.IO.Directory]::GetFiles($kubejsFolder, "*.*", [System.IO.SearchOption]::AllDirectories)
    foreach ($kf in $kjsFiles) {
        $rel = $kf.Substring($scriptRoot.Length).Replace("\", "/")
        if (-not $rel.StartsWith("/")) { $rel = "/" + $rel }
        $fn = [System.IO.Path]::GetFileName($kf)
        Registar-FicheiroLocal -FullPath $kf -RelativeVirtualPath $rel -AssetUploadName $fn -Type "script"
    }
}

# C) Configs (.json, .toml, .snbt, .txt)
if ([System.IO.Directory]::Exists($configFolder)) {
    $cfgFiles = [System.IO.Directory]::GetFiles($configFolder, "*.*", [System.IO.SearchOption]::AllDirectories)
    foreach ($cf in $cfgFiles) {
        $rel = $cf.Substring($scriptRoot.Length).Replace("\", "/")
        if (-not $rel.StartsWith("/")) { $rel = "/" + $rel }
        $fn = [System.IO.Path]::GetFileName($cf)
        Registar-FicheiroLocal -FullPath $cf -RelativeVirtualPath $rel -AssetUploadName $fn -Type "config"
    }
}

# D) Resourcepacks (.zip)
if ([System.IO.Directory]::Exists($resourcepacksFolder)) {
    $rpFiles = [System.IO.Directory]::GetFiles($resourcepacksFolder, "*.zip", [System.IO.SearchOption]::TopDirectoryOnly)
    foreach ($rp in $rpFiles) {
        $fn = [System.IO.Path]::GetFileName($rp)
        Registar-FicheiroLocal -FullPath $rp -RelativeVirtualPath "/resourcepacks/$fn" -AssetUploadName $fn -Type "resourcepack"
    }
}

Write-Host "Encontrados $($localFilesToSync.Count) ficheiros locais." -ForegroundColor Green

# Hashes
$contentListEntries = [System.Collections.Generic.List[PSCustomObject]]::new()
$indexFilesEntries = [System.Collections.Generic.List[PSCustomObject]]::new()

$sha1Engine = [System.Security.Cryptography.SHA1]::Create()
$sha256Engine = [System.Security.Cryptography.SHA256]::Create()

$count = 0
foreach ($item in $localFilesToSync) {
    $count++
    Write-Progress -Activity "A processar ficheiros locais" -Status "[$count/$($localFilesToSync.Count)] $($item.FileName)" -PercentComplete (($count / $localFilesToSync.Count) * 100)

    $fs = [System.IO.File]::OpenRead($item.FullPath)
    $sha1Bytes = $sha1Engine.ComputeHash($fs)
    $fs.Position = 0
    $sha256Bytes = $sha256Engine.ComputeHash($fs)
    $fs.Close()
    $fs.Dispose()

    $sha1Hex = [System.BitConverter]::ToString($sha1Bytes).Replace("-", "").ToLower()
    $sha256Hex = [System.BitConverter]::ToString($sha256Bytes).Replace("-", "").ToLower()

    $murmurVal = 0
    if ($item.FullPath.EndsWith(".jar", [System.StringComparison]::OrdinalIgnoreCase)) {
        try { $murmurVal = [CurseMurmurHash]::Compute($item.FullPath) } catch {}
    }

    $contentListEntries.Add([PSCustomObject]@{
        file = $item.RelativeVirtualPath
        size = [string]$item.Size
        type = $item.Type
        editable = ($item.Type -eq "config")
        forceCopy = ($item.Type -ne "mod")
        sha1 = $sha1Hex
        murmur = [string]$murmurVal
    })

    $indexFilesEntries.Add([PSCustomObject]@{
        path = $item.AssetUploadName
        hash = $sha256Hex
        size = $item.Size
    })
}

$sha1Engine.Dispose()
$sha256Engine.Dispose()
Write-Progress -Activity "A processar ficheiros locais" -Completed

# ============================================================================
# HISTORICO ACUMULATIVO DE MODS REMOVIDOS (nonModpackFilesToDelete)
# Garante que quem perdeu 2 ou mais updates continua a ter tudo limpo e sem duplicados!
# ============================================================================
$deletionsDict = [System.Collections.Generic.Dictionary[string, PSCustomObject]]::new([System.StringComparer]::OrdinalIgnoreCase)

# 1. Carregar historico acumulado persistente se existir
if (Test-Path $deletionsHistoryPath) {
    try {
        $rawHist = (Get-Content -Path $deletionsHistoryPath -Raw -Encoding UTF8).Trim([char]0xFEFF)
        if ($rawHist) {
            $histItems = $rawHist | ConvertFrom-Json
            foreach ($h in $histItems) {
                if ($h.file -and $h.sha1) {
                    $deletionsDict[$h.file] = $h
                }
            }
        }
    } catch {
        Write-Warning "Aviso ao carregar historico de remocoes ($deletionsHistoryPath): $_"
    }
}

# 2. Carregar do automodpack-content.json anterior se existir e comparar
if (Test-Path $contentJsonPath) {
    try {
        $rawPrev = (Get-Content -Path $contentJsonPath -Raw -Encoding UTF8).Trim([char]0xFEFF)
        if ($rawPrev) {
            $prevManifest = $rawPrev | ConvertFrom-Json
            if ($prevManifest.nonModpackFilesToDelete) {
                foreach ($h in $prevManifest.nonModpackFilesToDelete) {
                    if ($h.file -and $h.sha1 -and (-not $deletionsDict.ContainsKey($h.file))) {
                        $deletionsDict[$h.file] = $h
                    }
                }
            }

            # Comparar a lista de ficheiros anterior com a lista nova
            $currentRelativeFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $contentListEntries) {
                $null = $currentRelativeFiles.Add($entry.file)
            }

            $nowTimestamp = [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $novasRemocoes = 0

            if ($prevManifest.list) {
                foreach ($prevItem in $prevManifest.list) {
                    if (-not $currentRelativeFiles.Contains($prevItem.file)) {
                        # O ficheiro existia antes e ja nao existe agora: foi removido ou atualizado!
                        if (-not $deletionsDict.ContainsKey($prevItem.file)) {
                            $newDel = [PSCustomObject]@{
                                file = $prevItem.file
                                sha1 = $prevItem.sha1
                                timestamp = $nowTimestamp
                            }
                            $deletionsDict[$prevItem.file] = $newDel
                            $novasRemocoes++
                            Write-Host "  -> Novo mod obsoleto registado para remocao: $($prevItem.file)" -ForegroundColor Yellow
                        }
                    }
                }
            }
            if ($novasRemocoes -gt 0) {
                Write-Host "-> $novasRemocoes mod(s) obsoleto(s) adicionados ao historico de remocao." -ForegroundColor Green
            }
        }
    } catch {
        Write-Warning "Aviso ao comparar manifesto anterior: $_"
    }
}

# 3. Guardar historico acumulativo atualizado
$deletionsList = [System.Collections.Generic.List[PSCustomObject]]::new($deletionsDict.Values)
$deletionsListSorted = $deletionsList | Sort-Object file
$jsonDeletions = $deletionsListSorted | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($deletionsHistoryPath, $jsonDeletions, [System.Text.Encoding]::UTF8)
Write-Host "-> Historico cumulativo de remocoes contem $($deletionsListSorted.Count) ficheiro(s) obsoleto(s)." -ForegroundColor DarkGreen

# Gerar manifestos
$autoModpackManifest = [PSCustomObject]@{
    modpackName = "GL-Eternity-2026"
    automodpackVersion = "4.0.5"
    loader = "neoforge"
    loaderVersion = "21.1.250"
    mcVersion = "1.21.1"
    list = $contentListEntries
    nonModpackFilesToDelete = $deletionsListSorted
}
$jsonContent = $autoModpackManifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($contentJsonPath, $jsonContent, [System.Text.Encoding]::UTF8)

$autoModpackIndex = [PSCustomObject]@{
    version = 1
    files = $indexFilesEntries
}
$jsonIndex = $autoModpackIndex | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($indexJsonPath, $jsonIndex, [System.Text.Encoding]::UTF8)

Write-Host "-> Manifestos gerados: automodpack-content.json (com $($deletionsListSorted.Count) remocoes acumuladas) e automodpack-index.json" -ForegroundColor Green

# ============================================================================
# 3. MAPEAMENTO COMPLETO DA RELEASE REMOTA VIA GH API
# ============================================================================
Write-Host "`nA mapear ficheiros ja publicados na Release ($Tag)..." -ForegroundColor Cyan

$releaseInfo = (gh api "repos/$Repo/releases/tags/$Tag" | ConvertFrom-Json)
$releaseNumericId = $releaseInfo.id

$remoteAssets = @{}
$page = 1
while ($true) {
    $assetsPage = (gh api "repos/$Repo/releases/$releaseNumericId/assets?per_page=100&page=$page" | ConvertFrom-Json)
    $arr = @($assetsPage)
    if ($arr.Length -eq 0) { break }
    foreach ($a in $arr) {
        if ($a.name -and $a.id) {
            $remoteAssets[[string]$a.name] = [string]$a.id
        }
    }
    if ($arr.Length -lt 100) { break }
    $page++
}

Write-Host "-> Ficheiros ja publicados no GitHub: $($remoteAssets.Count)" -ForegroundColor Green

# Funcao de comparacao normalizada (trata sanitizacao de brackets/espacos do GitHub)
function Normalizar-NomeAsset ([string]$name) {
    if (-not $name) { return "" }
    return ($name -replace '[^a-zA-Z0-9]', '').ToLower()
}

$remoteAssetsNormalizados = @{}
foreach ($rawName in $remoteAssets.Keys) {
    $normKey = Normalizar-NomeAsset $rawName
    $remoteAssetsNormalizados[$normKey] = @{
        RawName = $rawName
        Id = $remoteAssets[$rawName]
    }
}

$localAssetNamesNormalizados = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($locName in $localAssetNames) {
    $null = $localAssetNamesNormalizados.Add((Normalizar-NomeAsset $locName))
}

# ============================================================================
# 4. PURGA DE FICHEIROS OBSOLETOS NA RELEASE
# ============================================================================
$deletedCount = 0
if (-not $SkipPurge) {
    Write-Host "`nA verificar ficheiros obsoletos para remocao..." -ForegroundColor Cyan
    $assetNames = [string[]]($remoteAssets.Keys)

    foreach ($assetName in $assetNames) {
        if ($assetName -eq "automodpack-content.json" -or $assetName -eq "automodpack-index.json") {
            continue
        }

        $assetNorm = Normalizar-NomeAsset $assetName
        if (-not $localAssetNamesNormalizados.Contains($assetNorm)) {
            $assetId = $remoteAssets[$assetName]
            Write-Host "-> A remover versao antiga da Release: $assetName" -ForegroundColor Red
            
            try {
                $endpointDel = "repos/$Repo/releases/assets/$assetId"
                & gh api -X DELETE $endpointDel | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $deletedCount++
                    $remoteAssets.Remove($assetName)
                }
            } catch {
                Write-Warning "Falha ao apagar $assetName : $_"
            }
        }
    }

    if ($deletedCount -gt 0) {
        Write-Host "-> $deletedCount ficheiros obsoletos eliminados da Release." -ForegroundColor Yellow
    } else {
        Write-Host "-> Nenhum ficheiro obsoleto detetado." -ForegroundColor DarkGray
    }
}

# ============================================================================
# 5. UPLOAD APENAS DO QUE FALTA (DELTA UPLOAD VIA GH CLI)
# ============================================================================
Write-Host "`nA calcular diferencas..." -ForegroundColor Cyan

$pendentes = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($item in $localFilesToSync) {
    $itemNorm = Normalizar-NomeAsset $item.AssetUploadName
    if (-not $remoteAssetsNormalizados.ContainsKey($itemNorm)) {
        $pendentes.Add($item)
    }
}

Write-Host "Ficheiros ja sincronizados no GitHub : $($localFilesToSync.Count - $pendentes.Count)" -ForegroundColor Green
Write-Host "Ficheiros novos a enviar             : $($pendentes.Count)" -ForegroundColor Yellow

$uploadedCount = 0
$failedUploads = [System.Collections.Generic.List[string]]::new()

if ($pendentes.Count -gt 0) {
    $idx = 0
    foreach ($fileItem in $pendentes) {
        $idx++
        $progStr = "[$idx/$($pendentes.Count)]"
        Write-Host "$progStr A enviar: $($fileItem.AssetUploadName) ($([math]::Round($fileItem.Size / 1KB, 1)) KB)..." -ForegroundColor White

        $success = $false
        $attempts = 0
        while (-not $success -and $attempts -lt 3) {
            $attempts++
            try {
                $encodedName = [System.Uri]::EscapeDataString($fileItem.AssetUploadName)
                $uploadUrl = "https://uploads.github.com/repos/$Repo/releases/$releaseNumericId/assets?name=$encodedName"

                $fileStream = [System.IO.File]::OpenRead($fileItem.FullPath)
                $content = [System.Net.Http.StreamContent]::new($fileStream)
                $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("application/octet-stream")

                $response = $httpClient.PostAsync($uploadUrl, $content).GetAwaiter().GetResult()

                $fileStream.Close()
                $fileStream.Dispose()
                $content.Dispose()

                if ($response.IsSuccessStatusCode) {
                    $success = $true
                } else {
                    Start-Sleep -Seconds 2
                }
            } catch {
                Start-Sleep -Seconds 2
            }
        }

        if ($success) {
            $uploadedCount++
            $remoteAssets[$fileItem.AssetUploadName] = 0
            Write-Host "$progStr Enviado com sucesso!" -ForegroundColor Green
        } else {
            $failedUploads.Add($fileItem.AssetUploadName)
            Write-Host "$progStr FALHA no envio de $($fileItem.AssetUploadName)!" -ForegroundColor Red
        }
    }
} else {
    Write-Host "-> Todos os $($localFilesToSync.Count) ficheiros ja estao atualizados no GitHub!" -ForegroundColor Green
}

# ============================================================================
# 6. UPLOAD SEGURO DOS MANIFESTOS (SEMPRE POR ULTIMO)
# ============================================================================
Write-Host "`nA atualizar manifestos na Release..." -ForegroundColor Yellow

gh release upload $Tag $contentJsonPath --repo $Repo --clobber
gh release upload $Tag $indexJsonPath --repo $Repo --clobber
Write-Host "-> Manifestos atualizados na Release com sucesso!" -ForegroundColor Green

# ============================================================================
# 7. COMMIT & PUSH GIT OPCIONAL
# ============================================================================
if ($AutoCommit) {
    Write-Host "`nA submeter alteracoes para o repositorio Git..." -ForegroundColor Cyan
    git -C $scriptRoot add automodpack-content.json automodpack-index.json automodpack-deletions-history.json
    if ([System.IO.Directory]::Exists($kubejsFolder)) { git -C $scriptRoot add kubejs }
    if ([System.IO.Directory]::Exists($configFolder)) { git -C $scriptRoot add config }

    $statusOut = git -C $scriptRoot status --porcelain
    if ($statusOut) {
        $commitMsg = "AutoModpack Sync: Atualizados manifestos e assets ($uploadedCount novos, $deletedCount removidos)"
        git -C $scriptRoot commit -m $commitMsg
        gh auth setup-git 2>$null
        git -C $scriptRoot push origin main
        Write-Host "-> Alteracoes enviadas para o branch main do GitHub com sucesso!" -ForegroundColor Green
    } else {
        Write-Host "-> Nenhuma alteracao pendente para commit." -ForegroundColor DarkGray
    }
}

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host "PROCESSO CONCLUIDO COM SUCESSO!" -ForegroundColor Green
Write-Host "   Ficheiros verificados  : $($localFilesToSync.Count)" -ForegroundColor White
Write-Host "   Novos uploads          : $uploadedCount" -ForegroundColor Green
Write-Host "   Obsoletos removidos    : $deletedCount" -ForegroundColor Yellow
if ($failedUploads.Count -gt 0) {
    Write-Host "   Falhas                : $($failedUploads.Count) ($($failedUploads -join ', '))" -ForegroundColor Red
}
Write-Host "=================================================================" -ForegroundColor Green