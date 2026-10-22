# Image Asset Manager — model catalogue

The app reads `catalogue/v1/models.json` from this branch at launch, every 24 hours and on demand.

- Pushing here **publishes** a model change to every installed copy. Code merges never touch this branch.
- Raise `revision` on every change. A rollback is the old content under a **higher** revision.
- The app rejects a file that breaks its bounds (spec v0.3 §5.2) and keeps the previous catalogue.
- Keep the bundled copy on `develop` (`catalogue/v1/models.json`) in step at each release.
