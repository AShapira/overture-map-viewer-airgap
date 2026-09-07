import com.onthegomap.planetiler.FeatureCollector;
import com.onthegomap.planetiler.Planetiler;
import com.onthegomap.planetiler.Profile;
import com.onthegomap.planetiler.config.Arguments;
import com.onthegomap.planetiler.reader.SourceFeature;
import com.onthegomap.planetiler.reader.parquet.ParquetFeature;
import com.onthegomap.planetiler.reader.parquet.S3InputFiles;
import com.onthegomap.planetiler.util.Glob;
import org.apache.parquet.schema.MessageType;

import java.nio.file.Path;
import java.util.List;

public class OvertureProfile implements Profile {

    public interface Theme {
        void processFeature(SourceFeature source, FeatureCollector features);

        String name();
    }

    private Theme theme;

    public OvertureProfile(Theme theme) {
        this.theme = theme;
    }

    protected static void addFullTags(SourceFeature source, FeatureCollector.Feature feature, int minZoomToShowAlways) {
        if (source instanceof ParquetFeature pf) {
            MessageType schema = pf.parquetSchema();
            for (var field : schema.getFields()) {
                var name = field.getName();
                if (!pf.hasTag(name)) continue;
                if (name.equals("bbox") || name.equals("geometry")) continue;
                if (name.equals("names")) {
                    var names = pf.getStruct("names");
                    var rules = names.get("rules");
                    boolean hasBetween = !rules.isNull() && rules.asList().stream().anyMatch(rule -> !rule.get("between").isNull());
                    if (!hasBetween) {
                        var primaryName = pf.getStruct("names").get("primary");
                        feature.setAttrWithMinSize("@name", primaryName, 16, 0, minZoomToShowAlways);
                    }
                }
                if (field.isPrimitive()) {
                    feature.inheritAttrFromSource(name);
                    feature.setAttrWithMinSize(name, source.getTag(name), 16, 0, minZoomToShowAlways);
                } else {
                    feature.setAttrWithMinSize(name, source.getStruct(name).asJson(), 16, 0, minZoomToShowAlways);
                }
            }
        }
    }

    protected static FeatureCollector.Feature createAnyFeature(SourceFeature feature,
                                                               FeatureCollector features) {
        return feature.isPoint() ? features.point(feature.getSourceLayer()) :
                feature.canBePolygon() ? features.polygon(feature.getSourceLayer()) :
                        features.line(feature.getSourceLayer());
    }

    @Override
    public void processFeature(SourceFeature source, FeatureCollector features) {
        this.theme.processFeature(source, features);
    }

    @Override
    public boolean isOverlay() {
        return true;
    }

    @Override
    public String name() {
        return "Overture " + this.theme.name();
    }

    @Override
    public String description() {
        return "A tileset generated from Overture data";
    }

    @Override
    public String attribution() {
        return """
                <a href="https://www.openstreetmap.org/copyright" target="_blank">&copy; OpenStreetMap</a>
                <a href="https://docs.overturemaps.org/attribution" target="_blank">&copy; Overture Maps Foundation</a>
                """
                .replace("\n", " ")
                .trim();
    }

    static void run(Arguments args, Theme theme) throws Exception {
        String data = args.getString("data", "overture base directory or s3 URI", Path.of("data", "overture").toString());
        if (data.startsWith("s3://")) {
            try (var source = S3InputFiles.open(data, theme.name())) {
                run(args, theme, source.paths());
            }
        } else {
            Path base = args.inputFile("data", "overture base directory", Path.of(data));
            run(args, theme, Glob.of(base).resolve("theme=" + theme.name(), "*", "*.parquet").find());
        }
    }

    private static void run(Arguments args, Theme theme, List<Path> paths) throws Exception {
        Planetiler.create(args)
                .setProfile(new OvertureProfile(theme))
                .addParquetSource("overture",
                        paths,
                        true, // hive-partitioning
                        fields -> fields.get("id"), // hash the ID field to generate unique long IDs
                        fields -> fields.get("type")) // extract "type={}" from the filename to get layer
                .overwriteOutput(args.file("output", "output PMTiles archive", Path.of("data", theme.name() + ".pmtiles")))
                .run();
    }
}
