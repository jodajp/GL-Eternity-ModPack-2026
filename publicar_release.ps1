Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web

$repo = "jodajp/GL-Eternity-ModPack-2026"
$tag = "latest"
$modsFolder = Join-Path $PSScriptRoot "mods"
$outputIndex = Join-Path $PSScriptRoot "automodpack-index.json"

Write-Host "A calcular hashes dos mods locais..." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $modsFolder)) {
    Write-Error "Pasta de mods nao encontrada: $modsFolder"
    return
}

# 1. Obter token de autenticacao do GitHub CLI
$token = (gh auth token 2>$null)
if (-not $token) {
    Write-Error "Token do GitHub nao encontrado. Executa 'gh auth login' primeiro."
    return
}

# 2. Calcular SHA-256 e gerar o automodpack-index.json
$filesList = [System.Collections.Generic.List[PSCustomObject]]::new()
$sha256Managed = [System.Security.Cryptography.SHA256]::Create()
$jarFiles = Get-ChildItem -LiteralPath $modsFolder -Filter *.jar

foreach ($file in $jarFiles) {
    try {
        $fileStream = [System.IO.File]::OpenRead($file.FullName)
        $hashBytes = $sha256Managed.ComputeHash($fileStream)
        $fileStream.Close()
        $fileStream.Dispose()

        $hashString = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()

        $filesList.Add([PSCustomObject]@{
            path = $file.Name
            hash = $hashString
            size = $file.Length
        })
    } catch {
        Write-Warning "Falha ao ler $($file.Name): $_"
    }
}
$sha256Managed.Dispose()

$manifest = [PSCustomObject]@{
    version = 1
    files = $filesList
}

$jsonContent = $manifest | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($outputIndex, $jsonContent, [System.Text.Encoding]::UTF8)

# 3. Garantir que a Release 'latest' existe
gh release view $tag --repo $repo 2>$null
if ($LASTEXITCODE -ne 0) {
    gh release create $tag --title "Latest Build" --notes "Build sincronizada automaticamente" --repo $repo
}

# 4. Obter Release ID e lista completa de assets remotos de forma garantida
Write-Host "A ler metadados da Release remota..." -ForegroundColor Cyan

# Obter o ID numerico da Release
$releaseId = (gh api "repos/$repo/releases/tags/$tag" --jq ".id")
if (-not $releaseId) {
    Write-Error "Nao foi possivel obter o Release ID!"
    return
}

# Obter a lista completa de nomes de assets ja existentes (gh trata da paginacao)
$remoteAssetsList = gh release view $tag --repo $repo --json assets -q ".assets[].name"
$remoteAssets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($name in $remoteAssetsList) {
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        $null = $remoteAssets.Add($name.Trim())
    }
}

Write-Host "Release ID: $releaseId | Assets no GitHub: $($remoteAssets.Count)" -ForegroundColor Green

# 5. Atualizar o manifesto JSON na Release
Write-Host "A atualizar manifesto automodpack-index.json..." -ForegroundColor Yellow
gh release upload $tag $outputIndex --repo $repo --clobber

# 6. Sincronizacao delta via HttpClient
$httpClient = [System.Net.Http.HttpClient]::new()
$httpClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $token)
$httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("GL-Pack-Sync-Script")
$httpClient.Timeout = [System.TimeSpan]::FromMinutes(5)

$total = $jarFiles.Count
$current = 0
$uploadedCount = 0

foreach ($file in $jarFiles) {
    $current++
    $fileName = $file.Name

    # Smart Diff: salta se o asset ja estiver na Release
    if ($remoteAssets.Contains($fileName)) {
        Write-Host "[$current/$total] Ja sincronizado: $fileName" -ForegroundColor DarkGray
        continue
    }

    Write-Host "[$current/$total] A carregar: $fileName" -ForegroundColor Green

    try {
        $encodedName = [System.Uri]::EscapeDataString($fileName)
        $uploadUrl = "https://uploads.github.com/repos/$repo/releases/$releaseId/assets?name=$encodedName"

        $fileStream = [System.IO.File]::OpenRead($file.FullName)
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
            $null = $remoteAssets.Add($fileName)
            Write-Host "[$current/$total] Carregado com sucesso: $fileName" -ForegroundColor Green
        } elseif ($statusCode -eq 422 -or $respBody -match "already_exists") {
            # 422 com already_exists significa que ja esta no GitHub. Silencia o warning.
            Write-Host "[$current/$total] Ja sincronizado no GitHub: $fileName" -ForegroundColor DarkGray
            $null = $remoteAssets.Add($fileName)
        } else {
            Write-Warning "Falha no upload de $fileName (HTTP $statusCode): $respBody"
        }
    } catch {
        Write-Warning "Excecao ao carregar ${fileName}: $_"
    }
}

$httpClient.Dispose()

Write-Host "`nSincronizacao concluida com sucesso!" -ForegroundColor Green