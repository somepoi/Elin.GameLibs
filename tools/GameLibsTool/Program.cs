using System.Reflection.PortableExecutable;
using System.Reflection.Metadata;
using System.Security.Cryptography;
using System.Text.Json;
using System.Xml.Linq;

try
{
    var root = Path.GetFullPath(args.Single());
    using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "provenance.json")));
    var data = manifest.RootElement;
    if (data.GetProperty("schemaVersion").GetInt32() != 2)
        throw new InvalidDataException("Unsupported snapshot schema; regenerate it with Update-GameLibs.ps1.");
    if (data.GetProperty("steamAppId").GetInt32() != 2135150)
        throw new InvalidDataException("Snapshot does not belong to Elin.");
    var properties = XDocument.Load(Path.Combine(root, "GameLibs.props")).Descendants("PropertyGroup").Single();
    var buildId = properties.Element("SteamBuildId")!.Value;
    var gameVersion = properties.Element("GameVersion")!.Value;
    var revision = properties.Element("PackageRevision")!.Value;
    if (!Version.TryParse(gameVersion, out var parsedVersion) || parsedVersion.Build < 0 ||
        gameVersion != parsedVersion.ToString(parsedVersion.Revision > 0 ? 4 : 3) ||
        !int.TryParse(revision, out var packageRevision) || packageRevision < 0)
        throw new InvalidDataException("Invalid game version or package revision.");
    var version = packageRevision == 0 ? gameVersion : $"{gameVersion}-repack.{packageRevision}";
    var versionProperties = properties.Elements("PackageVersion").ToArray();
    if (versionProperties.Length != 2 || versionProperties[0].Value != "$(GameVersion)" ||
        versionProperties[0].Attribute("Condition") != null ||
        versionProperties[1].Value != "$(GameVersion)-repack.$(PackageRevision)" ||
        versionProperties[1].Attribute("Condition")?.Value != "'$(PackageRevision)' != '0'")
        throw new InvalidDataException("PackageVersion must follow the game version and package revision.");
    if (data.GetProperty("gameVersion").GetString() != gameVersion ||
        data.GetProperty("steamBuildId").GetString() != buildId ||
        data.GetProperty("revision").GetInt32().ToString() != revision ||
        data.GetProperty("packageVersion").GetString() != version)
        throw new InvalidDataException("Package version and snapshot provenance disagree.");
    var assemblies = data.GetProperty("assemblies").EnumerateArray().ToArray();
    var expected = assemblies.Select(a => a.GetProperty("name").GetString()!).Order().ToArray();
    var directory = Path.Combine(root, "references");
    var actual = Directory.GetFiles(directory, "*.dll").Select(Path.GetFileName).Order().ToArray();
    if (!actual.SequenceEqual(expected) || !expected.Contains("Elin.dll"))
        throw new InvalidDataException("Reference files differ from the recorded snapshot.");
    foreach (var entry in assemblies)
    {
        var name = entry.GetProperty("name").GetString()!;
        if (Path.GetFileName(name) != name)
            throw new InvalidDataException($"Invalid assembly filename: {name}");
        var sourceHash = entry.GetProperty("sourceSha256").GetString();
        if (sourceHash != entry.GetProperty("referenceSha256").GetString())
            throw new InvalidDataException($"Reference is not an original game DLL: {name}");
        using var stream = File.OpenRead(Path.Combine(directory, name));
        if (Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() != sourceHash)
            throw new InvalidDataException($"Reference hash mismatch: {name}");
        stream.Position = 0;
        using var pe = new PEReader(stream);
        var metadata = pe.GetMetadataReader();
        var assembly = metadata.GetAssemblyDefinition();
        if (assembly.Version.ToString() != entry.GetProperty("assemblyVersion").GetString())
            throw new InvalidDataException($"Assembly version mismatch: {name}");
    }
    Console.WriteLine($"GameLibs {version} for Elin {gameVersion}: {assemblies.Length} full compiler assemblies.");
    var output = Environment.GetEnvironmentVariable("GITHUB_OUTPUT");
    if (!string.IsNullOrEmpty(output))
        File.AppendAllText(output, $"version={version}\ngame_version={gameVersion}\nsteam_build={buildId}\nassembly_count={assemblies.Length}\n");
    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine(error.Message);
    return 1;
}
