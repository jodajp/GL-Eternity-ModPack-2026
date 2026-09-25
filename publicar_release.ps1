Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web

# ==========================================
# 0. CONFIGURAÇÕES
# ==========================================
$repo = "jodajp/GL-Eternity-ModPack-2026"
$tag = "latest"
$modsFolder = [System.IO.Path]::Combine(($PSScriptRoot), "mods")
$outputIndex = [System.IO.Path]::Combine(($PSScriptRoot), "automodpack-index.json")

if (-not [System.IO.Directory]::Exists($modsFolder)) {
    Write-Error "Pasta de mods nao encontrada: $modsFolder"
    return
}

# 1. Obter token do GitHub CLI autenticado
$token = (gh auth token 2>$null)
if (-not $token) {
    Write-Error "Token do GitHub nao encontrado. Executa 'gh auth login' primeiro."
    return
}

# Configuracao do cliente HTTP .NET
$httpClient = [System.Net.Http.HttpClient]::new()
$httpClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", ($token))
$httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("GL-Pack-Sync-Script")
$httpClient.Timeout = [System.TimeSpan]::FromMinutes(5)

try {
    # ==========================================
    # 2. CALCULAR HASHES E GERAR MANIFESTO
    # ==========================================
    Write-Host "A calcular hashes dos mods locais..." -ForegroundColor Cyan

    $filesList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $localFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $sha256Managed = [System.Security.Cryptography.SHA256]::Create()
    
    $jarFiles = [System.IO.Directory]::GetFiles(($modsFolder), "*.jar")

    for ($i = 0; $i -lt$jarFiles.Length; $i++) {$filePath = $jarFiles[$i]
        $fileName = [System.IO.Path]::GetFileName($filePath)
        $fileInfo = [System.IO.FileInfo]::new($filePath)
        try {
            $fileStream = [System.IO.File]::OpenRead($filePath)
            $hashBytes = $sha256Managed.ComputeHash($fileStream)
            $fileStream.Close()
            $fileStream.Dispose()

            $hashString = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()

            $filesList.Add([PSCustomObject]@{
                path = $fileName
                hash = $hashString
                size = $fileInfo.Length
            })
            $null = $localFileNames.Add($fileName)
        } catch {
            Write-Warning "Falha ao ler $($fileName):$_"
        }
    }
    $sha256Managed.Dispose()

    $manifest = [PSCustomObject]@{
        version = 1
        files = $filesList
    }

    $jsonContent =$manifest | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText(($outputIndex),$jsonContent, [System.Text.Encoding]::UTF8)

    Write-Host "Hashes concluidos ($($filesList.Count) mods locais)." -ForegroundColor Cyan

    # ==========================================
    # 3. GARANTIR RELEASE 'latest' E OBTER ID
    # ==========================================
    gh release view ($tag) --repo ($repo) 2>$null
    if ($LASTEXITCODE -ne 0) {
        gh release create ($tag) --title "Latest Build" --notes "Build sincronizada automaticamente" --repo ($repo)
    }

    Write-Host "A mapear assets remotos da Release..." -ForegroundColor Cyan

    # Obter dados da release diretamente via REST API do GitHub (.NET puro)
    $relUrl = "https://api.github.com/repos/$repo/releases/tags/$tag"
    $relReq = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $relUrl)
    $relResp = $httpClient.SendAsync($relReq).GetAwaiter().GetResult()
    $relJson = $relResp.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json

    $releaseNumericId = $relJson.id
    $remoteAssets = @{}

    # ==========================================
    # 4. MAPEAMENTO ROBUSTO DOS ASSETS REMOTOS
    # ==========================================
    Write-Host "A mapear assets remotos da Release..." -ForegroundColor Cyan

    # Obter Release ID numérico
    $relData = (gh api "repos/$repo/releases/tags/$tag" | ConvertFrom-Json)
    $releaseNumericId = $relData.id

    $remoteAssets = @{}
    $page = 1

    while ($true) {
        # Lê a página crua via gh api
        $jsonText = gh api "repos/$repo/releases/$releaseNumericId/assets?per_page=100&page=$page" 2>$null
        if (-not $jsonText) { break }

        $pageItems = ConvertFrom-Json -InputObject $jsonText
        
        # Garante que é tratado estritamente como array
        $itemsArray = @($pageItems)
        if ($itemsArray.Length -eq 0) { break }

        for ($idx = 0; $idx -lt $itemsArray.Length; $idx++) {
            $singleAsset = $itemsArray[$idx]
            if ($singleAsset.name -and $singleAsset.id) {
                # Mapeamento 1:1 estrito
                $remoteAssets[[string]$singleAsset.name] = [string]$singleAsset.id
            }
        }

        if ($itemsArray.Length -lt 100) { break }
        $page++
    }

    Write-Host "Release ID: $releaseNumericId | Assets reais no GitHub: $($remoteAssets.Count)" -ForegroundColor Green

    # ==========================================
    # 5. PURGA DE FICHEIROS OBSOLETOS (.jar)
    # ==========================================
    Write-Host "`nA verificar versoes antigas para eliminar..." -ForegroundColor Cyan
    $deletedCount = 0

    $assetNames = [string[]]($remoteAssets.Keys)

    for ($idx = 0; $idx -lt $assetNames.Length; $idx++) {
        $assetName = $assetNames[$idx]

        # Apenas mods .jar (o manifesto index.json fica intocado)
        if ($assetName.EndsWith(".jar", [System.StringComparison]::OrdinalIgnoreCase)) {
            if (-not $localFileNames.Contains($assetName)) {
                $assetId = $remoteAssets[$assetName]
                Write-Host "A remover versao obsoleta: $assetName (ID: $assetId)" -ForegroundColor Red
                
                try {
                    $deleteUrl = "https://api.github.com/repos/$repo/releases/assets/$assetId"
                    $delResp = $httpClient.DeleteAsync($deleteUrl).GetAwaiter().GetResult()
                    
                    if ($delResp.IsSuccessStatusCode) {
                        $deletedCount++
                        $remoteAssets.Remove($assetName)
                    } else {
                        Write-Warning "Falha ao apagar $assetName (HTTP $($delResp.StatusCode))"
                    }
                } catch {
                    Write-Warning "Erro ao tentar apagar ${assetName}: $_"
                }
            }
        }
    }

    if ($deletedCount -gt 0) {
        Write-Host "Limpeza concluida: $deletedCount ficheiro(s) antigo(s) removido(s) do GitHub." -ForegroundColor Yellow
    } else {
        Write-Host "Nenhum ficheiro obsoleto detetado." -ForegroundColor DarkGray
    }

    # ==========================================
    # 6. ATUALIZAR MANIFESTO JSON
    # ==========================================
    Write-Host "`nA atualizar manifesto automodpack-index.json..." -ForegroundColor Yellow
    gh release upload ($tag) ($outputIndex) --repo ($repo) --clobber

    # ==========================================
    # 7. UPLOAD DELTA DE MODS NOVOS / MODIFICADOS
    # ==========================================
    Write-Host "`nA sincronizar mods em falta..." -ForegroundColor Cyan
    $total = $jarFiles.Length
    $current = 0
    $uploadedCount = 0

    for ($i = 0; $i -lt $jarFiles.Length; $i++) {
        $current++
        $filePath = $jarFiles[$i]
        $fileName = [System.IO.Path]::GetFileName($filePath)

        if ($remoteAssets.ContainsKey($fileName)) {
            Write-Host "[$current/$total] Ja sincronizado: $fileName" -ForegroundColor DarkGray
            continue
        }

        Write-Host "[$current/$total] A carregar: $fileName" -ForegroundColor Green

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

            $statusCode = [int]$response.StatusCode
            $respBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

            if ($response.IsSuccessStatusCode) {
                $uploadedCount++
                $remoteAssets[$fileName] = 0
                Write-Host "[$current/$total] Carregado com sucesso!" -ForegroundColor Green
            } elseif ($statusCode -eq 422 -or $respBody -match "already_exists") {
                Write-Host "[$current/$total] Ja sincronizado no GitHub: $fileName" -ForegroundColor DarkGray
                $remoteAssets[$fileName] = 0
            } else {
                Write-Warning "Falha no upload de $fileName (HTTP $statusCode): $respBody"
            }
        } catch {
            Write-Warning "Excecao ao carregar ${fileName}: $_"
        }
    }

    Write-Host "`nSincronizacao concluida com sucesso!" -ForegroundColor Green
    Write-Host "Mods novos enviados: $uploadedCount | Ficheiros obsoletos removidos: $deletedCount \vert{} Total ativo:$total" -ForegroundColor Cyan

} finally {
    $httpClient.Dispose()
}