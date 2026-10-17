package kr.tteona.mapapi.building;

import java.nio.file.Path;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * 실행할 때 --mapapi.import.osm=파일경로 를 주면 서버 시작 직후 한 번 적재한다.
 * 옵션이 없으면 이 클래스 자체가 만들어지지 않는다(@ConditionalOnProperty). 평소 실행에는 영향 없음.
 */
@Component
@ConditionalOnProperty("mapapi.import.osm")
class ImportRunner implements ApplicationRunner {

	private static final Logger log = LoggerFactory.getLogger(ImportRunner.class);

	private final OsmBuildingImporter importer;

	ImportRunner(OsmBuildingImporter importer) {
		this.importer = importer;
	}

	@Override
	public void run(ApplicationArguments args) throws Exception {
		String file = args.getOptionValues("mapapi.import.osm").getFirst();
		int count = importer.importFile(Path.of(file));
		log.info("OSM 건물 {}개 적재(upsert) 완료: {}", count, file);
	}
}
