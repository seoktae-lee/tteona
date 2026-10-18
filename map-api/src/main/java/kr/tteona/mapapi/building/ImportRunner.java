package kr.tteona.mapapi.building;

import java.nio.file.Path;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

/**
 * 서버 시작 직후 한 번 적재한다. 둘 다 여러 번 줄 수 있다.
 *  --mapapi.import.osm=파일      성수 앱 시안 형식(로컬 좌표)
 *  --mapapi.import.geojson=파일  표준 GeoJSON(scripts/fetch_osm.py 출력, 건물·물)
 * 옵션이 없으면 아무것도 하지 않는다. 같은 파일을 다시 넣어도 결과가 같다(멱등).
 */
@Component
class ImportRunner implements ApplicationRunner {

	private static final Logger log = LoggerFactory.getLogger(ImportRunner.class);

	private final OsmBuildingImporter osm;
	private final GeoJsonImporter geoJson;

	ImportRunner(OsmBuildingImporter osm, GeoJsonImporter geoJson) {
		this.osm = osm;
		this.geoJson = geoJson;
	}

	@Override
	public void run(ApplicationArguments args) throws Exception {
		for (String file : values(args, "mapapi.import.osm")) {
			int count = osm.importFile(Path.of(file));
			log.info("OSM 건물 {}개 적재(upsert) 완료: {}", count, file);
		}
		for (String file : values(args, "mapapi.import.geojson")) {
			GeoJsonImporter.Result r = geoJson.importFile(Path.of(file));
			log.info("GeoJSON 건물 {}개 · 물 {}개 · 도로 {}개 적재(upsert) 완료: {}", r.buildings(), r.water(), r.roads(), file);
		}
	}

	private static java.util.List<String> values(ApplicationArguments args, String name) {
		var v = args.getOptionValues(name);
		return v == null ? java.util.List.of() : v;
	}
}
